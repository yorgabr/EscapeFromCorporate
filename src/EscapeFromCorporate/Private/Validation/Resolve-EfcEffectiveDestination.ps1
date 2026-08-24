#Requires -Version 5.1
<#
.SYNOPSIS
    Resolves the actual robocopy destination using rsync-style trailing-slash semantics.

.DESCRIPTION
    Mirrors rsync's well-known SRC/DEST convention exactly: a trailing
    separator on Source ('C:\Data\') means "copy the CONTENTS of Source into
    Destination" (robocopy's native /E behavior, unchanged). The ABSENCE of a
    trailing separator ('C:\Data') means "copy Source itself AS A SUBFOLDER of
    Destination" - the effective destination becomes Destination\<leaf name
    of Source>.

    BREAKING CHANGE (v2.0.0): prior versions always used contents-only
    semantics regardless of trailing slash. Any existing script or scheduled
    task calling efc without a trailing separator on -Source will now land
    files one directory level deeper than before.

.PARAMETER Source
    The requested source path, exactly as supplied by the caller.

.PARAMETER Destination
    The requested destination path, exactly as supplied by the caller.

.OUTPUTS
    [string] the effective destination robocopy should actually write to.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Resolve-EfcEffectiveDestination {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination
    )

    Set-StrictMode -Version Latest

    if ($Source -match '[\\/]$') {
        return $Destination
    }

    # NOTE: deliberately using -replace (regex), NOT .TrimEnd('\', '/').
    # TrimEnd(params char[]) called with two separate string arguments here
    # triggered a PowerShell method-overload/char-array binding failure at
    # runtime ("Cadeia de caracteres deve ter exatamente um caractere de
    # comprimento" / value "" cannot convert to Char), even though neither
    # '\' nor '/' is actually empty. Every other trim in this codebase only
    # ever passed TrimEnd a single character, so this two-argument form was
    # never exercised before. -replace with a regex character class sidesteps
    # .NET overload resolution entirely and is the same technique already
    # used elsewhere in this project (Test-EfcPreflight, ConvertFrom-RobocopyLine).
    $trimmedSource = $Source -replace '[\\/]+$', ''

    # --- Degenerate-root guard: MUST run before any leaf extraction ------------
    # 'C:' (a bare drive letter, no separator) is NOT an empty/opaque string to
    # PowerShell - it is a Windows "drive-relative path", a distinct concept
    # meaning "the current working directory on that drive for this session".
    # Split-Path -Leaf resolves it via the filesystem provider against that
    # live working directory rather than treating it as literal text, so
    # Split-Path -Leaf 'C:' can return something like 'EscapeFromCorporate' if
    # that happens to be the current directory - a completely
    # session-dependent, non-deterministic result. For a tool whose entire
    # purpose is preventing accidental data-destination mistakes, silently
    # nesting under a value that depends on the caller's $PWD at invocation
    # time would be exactly the kind of surprise this guard exists to avoid.
    # A bare UNC root ('\\server' or '\\server\share') is equally leaf-less
    # and is guarded the same way, without ever reaching leaf extraction.
    $isBareDriveRoot = $trimmedSource -match '^[A-Za-z]:$'
    $isBareUncRoot   = $trimmedSource -match '^\\\\[^\\]+(\\[^\\]+)?$'

    if ($isBareDriveRoot -or $isBareUncRoot) {
        return $Destination
    }

    # --- Leaf extraction: pure string/regex, no filesystem-provider cmdlet ---
    # The literal-path form of the path-splitting cmdlet lives in its own
    # exclusive parameter set that declares NONE of the mode switches (leaf,
    # parent, qualifier, etc.). Pairing the literal-path parameter with any
    # mode switch is a terminating ParameterBindingException raised during
    # parameter binding itself, so -ErrorAction SilentlyContinue cannot
    # suppress it - PSScriptAnalyzer cannot flag it either, since both
    # parameters are individually valid on their own. See
    # tests/Unit/SourceHygiene.Tests.ps1, which asserts this combination
    # never appears anywhere under src/.
    #
    # Strip a leading drive-relative prefix ('C:' not followed by a
    # separator, e.g. 'C:Data') first, then split on both separator styles
    # and take the last non-empty segment. This still never consults $PWD.
    $stripped = $trimmedSource -replace '^[A-Za-z]:(?![\\/])', ''
    $segments = @($stripped -split '[\\/]' | Where-Object { $_ -ne '' })

    $leaf = if ($segments.Count -gt 0) { $segments[-1] } else { $null }

    if ([string]::IsNullOrWhiteSpace($leaf)) {
        # Any other unexpected leaf-less shape: fail safe to content-copy
        # semantics rather than guessing.
        return $Destination
    }

    return Join-Path $Destination $leaf
}