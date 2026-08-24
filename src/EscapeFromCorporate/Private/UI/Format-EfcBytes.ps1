#Requires -Version 5.1
<#
.SYNOPSIS
    Formats a byte count into a human-readable binary-prefixed string.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Format-EfcBytes {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long] $Bytes
    )

    if ($Bytes -le 0) { return '0 B' }

    $units = 'B', 'KB', 'MB', 'GB', 'TB', 'PB'
    $idx   = [Math]::Floor([Math]::Log($Bytes, 1024))
    $idx   = [Math]::Min($idx, $units.Count - 1)
    $value = $Bytes / [Math]::Pow(1024, $idx)

    return ('{0:N2} {1}' -f $value, $units[$idx])
}
