#Requires -Version 5.1
<#
.SYNOPSIS
    Reduces a path to the identity of the drive or share that holds it.

.DESCRIPTION
    Returns a comparable, upper-case key:
        'C:\Data\x'                  -> 'C:'
        '\\?\C:\Data'                -> 'C:'
        '\\NAS\Backup\x'             -> '\\NAS\BACKUP'
        '\\?\UNC\nas\backup\x'       -> '\\NAS\BACKUP'
        '\\localhost\c$\x'           -> 'C:'       (admin share of THIS machine = a local drive)
        '\\<this-pc>\D$'             -> 'D:'
        '\\?\Volume{GUID}\x'         -> 'VOLUME:{GUID}'
    Returns $null when no drive/share can be determined (relative path, garbage).

    Deliberately NOT handled: non-administrative shares of the local machine
    (e.g. '\\localhost\docs'); mapping them back to a folder needs privileges or
    WMI that are not guaranteed for a standard user.

.PARAMETER LocalNames
    Names that mean "this machine". Defaults to localhost, 127.0.0.1, ::1, '.',
    and the machine name. Injectable for tests.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function ConvertTo-EfcDriveKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [string[]] $LocalNames
    )

    Set-StrictMode -Version Latest

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    if (-not $PSBoundParameters.ContainsKey('LocalNames')) {
        $LocalNames = @('localhost', '127.0.0.1', '::1', '.', $env:COMPUTERNAME, [System.Environment]::MachineName) |
            Where-Object { $_ }
    }

    $p = $Path.Trim()

    if ($p -match '^\\\\[?.]\\Volume\{([0-9A-Fa-f\-]+)\}') {
        return ('VOLUME:{' + $Matches[1].ToUpperInvariant() + '}')
    }

    $p = ConvertTo-EfcPlainPath -Path $p

    if ($p -match '^([A-Za-z]):') {
        return ($Matches[1].ToUpperInvariant() + ':')
    }

    if ($p -match '^\\\\([^\\/]+)\\([^\\/]+)') {
        $server = $Matches[1]
        $share  = $Matches[2]

        if ($share -match '^([A-Za-z])\$$' -and ($LocalNames -contains $server)) {
            return ($Matches[1].ToUpperInvariant() + ':')
        }
        return ('\\' + $server.ToUpperInvariant() + '\' + $share.ToUpperInvariant())
    }

    return $null
}
