#Requires -Version 5.1
<#
.SYNOPSIS
    Parses a single robocopy log line into a structured entry.

.DESCRIPTION
    With flags /BYTES /NC /TS /NP, per-file lines follow a predictable shape:
        <TAB><timestamp><whitespace><size><whitespace><fullpath>
    Directory lines and error lines carry distinct signatures. This parser uses
    a compiled regex to classify each line and extract metrics with minimal
    allocation overhead across hundreds of thousands of lines.

.PARAMETER Line
    A single, complete log line (no trailing newline).

.OUTPUTS
    PSCustomObject with: Type, Size, Path, TimestampRaw  (or $null if unparseable).

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>

# --- Script-scoped regex cache: eagerly initialized at import time ---------
# Set-StrictMode -Version Latest is in effect at the module's defining scope
# (EscapeFromCorporate.psm1). Under that mode, reading a $script: variable
# that has never been assigned throws "A variável '...' não pode ser
# recuperada porque ainda não foi definida" - even inside `if (-not $var)`.
# $null is NOT an acceptable "unset" state; the variable must exist. These
# four lines run once, when this file is dot-sourced into module scope, so
# the lazy-compile check below (`if (-not $script:EfcRxNewFile)`) is safe.
$script:EfcRxNewFile   = $null
$script:EfcRxSizedFile = $null
$script:EfcRxDir       = $null
$script:EfcRxError     = $null

function ConvertFrom-RobocopyLine {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Line
    )

    # --- Compiled regexes (module-scoped cache) --------------------------------
    if (-not $script:EfcRxNewFile) {
        $opts = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

        # New file: optional leading tabs, action label, size (bytes), path.
        # Path uses a possessive-style bounded match to avoid catastrophic
        # backtracking: consume everything up to trailing whitespace greedily,
        # then trim in code rather than with a lazy quantifier.
        $script:EfcRxNewFile = [regex]::new(
            '^\s*(?<action>New File|Newer|Older|Changed|\*EXTRA File)\s+(?<size>\d{1,19})\s+(?<path>\S.{0,4096})$',
            $opts)

        # Plain per-file line with /NC: "\t   <size>\t<path>" (no action label).
        $script:EfcRxSizedFile = [regex]::new(
            '^\s+(?<size>\d+)\s+(?<path>[A-Za-z]:\\.+|\\\\.+?\\.+)\s*$',
            $opts)

        # Directory marker: "\t   New Dir          N\t<path>" or similar.
        $script:EfcRxDir = [regex]::new(
            '^\s*New Dir\s+(?<count>\d+)?\s*(?<path>.+?)\s*$',
            $opts)

        # Error line: "ERROR n (0x0000000n) ..." 
        $script:EfcRxError = [regex]::new(
            '^\s*ERROR\s+(?<code>\d+)\s+\((?<hex>0x[0-9A-Fa-f]+)\)\s*(?<detail>.+)?$',
            $opts)
    }

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    # --- Defensive length guard against catastrophic regex backtracking --------
    # Real robocopy lines with /BYTES are bounded; a pathologically long line is
    # either corruption or an attack surface. Windows MAX_PATH-era paths plus the
    # action label and size fit comfortably under 4096 chars. Anything longer is
    # rejected as unparseable rather than risking exponential backtracking.
    if ($Line.Length -gt 4096) {
        return $null
    }

    # --- Classification order: cheapest / most frequent first ------------------
    $m = $script:EfcRxNewFile.Match($Line)
    if ($m.Success) {
        return [pscustomobject]@{
            Type         = 'File'
            Action       = $m.Groups['action'].Value
            Size         = [long]$m.Groups['size'].Value
            Path         = $m.Groups['path'].Value.TrimEnd()   # trim in code, not regex
            TimestampRaw = $null
        }
    }

    $m = $script:EfcRxSizedFile.Match($Line)
    if ($m.Success) {
        return [pscustomobject]@{
            Type         = 'File'
            Action       = 'Copy'
            Size         = [long]$m.Groups['size'].Value
            Path         = $m.Groups['path'].Value
            TimestampRaw = $null
        }
    }

    $m = $script:EfcRxDir.Match($Line)
    if ($m.Success) {
        return [pscustomobject]@{
            Type         = 'Dir'
            Action       = 'NewDir'
            Size         = [long]0
            Path         = $m.Groups['path'].Value
            TimestampRaw = $null
        }
    }

    $m = $script:EfcRxError.Match($Line)
    if ($m.Success) {
        return [pscustomobject]@{
            Type         = 'Error'
            Action       = 'Error'
            Size         = [long]0
            Path         = if ($m.Groups['detail'].Success) { $m.Groups['detail'].Value } else { '' }
            TimestampRaw = $m.Groups['code'].Value
        }
    }

    # Unrecognized (banner, blank, separator) -> ignored by caller.
    return $null
}