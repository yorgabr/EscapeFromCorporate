#Requires -Version 5.1
<#
.SYNOPSIS
    Strips the Win32 extended-length / device prefixes from a path.

.DESCRIPTION
    '\\?\C:\x'            -> 'C:\x'
    '\\?\UNC\srv\sh\x'    -> '\\srv\sh\x'
    '\\.\C:\x'            -> 'C:\x'
    Anything else is returned trimmed and otherwise unchanged. Pure string logic.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function ConvertTo-EfcPlainPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path
    )

    Set-StrictMode -Version Latest

    $p = $Path.Trim()

    if ($p -match '^\\\\\?\\UNC\\(.+)$') {
        return ('\\' + $Matches[1])
    }
    if ($p -match '^\\\\[?.]\\([A-Za-z]:.*)$') {
        return $Matches[1]
    }
    return $p
}
