#Requires -Version 5.1
<#
.SYNOPSIS
    Parses a single robocopy log line into a structured entry (locale-neutral).

.DESCRIPTION
    Designed against REAL robocopy output captured on pt-BR Windows (see
    tests/Unit/RobocopyRealOutput.Tests.ps1). The recommended flag set is
        /BYTES /NC /NDL /FP /NP /NJH /NJS
    which yields only per-file lines of the shape
        <ws><size><ws><full path>
    and error lines of the shape
        [yyyy/MM/dd HH:mm:ss ]<LOCALIZED WORD> <n> (0x<hex>) <detail>

    The parser never depends on localized words:
      * File vs Dir is decided by the path, not by a label: a directory header
        ("<count> <path>\") always ends with a backslash, a file path never does.
      * An optional leading label ("New File", "Novo Arquivo", "*EXTRA File"...)
        is tolerated and ignored, so default-flag output and legacy fixtures
        keep working.
      * Errors are anchored on the "<code> (0x<hex>)" pair, not on the word ERROR.

    NOTE: lines produced with /TS and without /FP ("<size> <date> <relative
    name>") are intentionally NOT recognised: the directory context is missing,
    so they cannot be turned into a path. Do not pass /TS.

.PARAMETER Line
    A single, complete log line (no trailing newline).

.OUTPUTS
    PSCustomObject: Type (File|Dir|Error), Action, Size, Path, TimestampRaw,
    Code.  $null when the line is not recognised.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>

# Eagerly initialised: the module runs under Set-StrictMode -Version Latest, and
# reading a never-assigned $script: variable throws even inside `if (-not $x)`.
$script:EfcRxEntry = $null
$script:EfcRxError = $null

function ConvertFrom-RobocopyLine {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Line
    )

    if (-not $script:EfcRxEntry) {
        $opts = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

        # [label] <size|count> <absolute path>. The label (if any) starts with a
        # non-digit and contains no digits. Path = drive-letter or UNC root.
        $script:EfcRxEntry = [regex]::new(
            '^\s*(?:(?<label>[^\d\s][^\d]*?)\s+)?(?<num>\d{1,19})\s+(?<path>(?:[A-Za-z]:\\|\\\\)[^\r\n]*?)\s*$',
            $opts)

        # [timestamp] <word> <code> (0x<hex>) <detail>   - locale-neutral.
        $script:EfcRxError = [regex]::new(
            '^\s*(?:\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+)?(?<word>[^\d\s]\S*)\s+(?<code>\d+)\s+\((?<hex>0x[0-9A-Fa-f]+)\)\s*(?<detail>.*?)\s*$',
            $opts)
    }

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    # Bounded input: protects against pathological lines (corruption/attack).
    if ($Line.Length -gt 4096) { return $null }

    $m = $script:EfcRxEntry.Match($Line)
    if ($m.Success) {
        $path  = $m.Groups['path'].Value
        $label = if ($m.Groups['label'].Success) { $m.Groups['label'].Value.Trim() } else { '' }

        if ($path.EndsWith('\')) {
            return [pscustomobject]@{
                Type         = 'Dir'
                Action       = 'NewDir'
                Size         = [long]0
                Path         = $path
                TimestampRaw = $null
                Code         = $null
            }
        }

        return [pscustomobject]@{
            Type         = 'File'
            Action       = $(if ($label) { $label } else { 'Copy' })
            Size         = [long]$m.Groups['num'].Value
            Path         = $path
            TimestampRaw = $null
            Code         = $null
        }
    }

    $m = $script:EfcRxError.Match($Line)
    if ($m.Success) {
        return [pscustomobject]@{
            Type         = 'Error'
            Action       = 'Error'
            Size         = [long]0
            Path         = $m.Groups['detail'].Value
            TimestampRaw = $m.Groups['code'].Value   # kept for backward compatibility
            Code         = [int]$m.Groups['code'].Value
        }
    }

    return $null
}
