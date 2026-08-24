#Requires -Version 5.1
<#
.SYNOPSIS
    Gracefully terminates the background robocopy process.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Stop-RobocopyProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Process
    )

    Set-StrictMode -Version Latest

    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
            [void] $Process.WaitForExit(5000)
        }
    }
    catch {
        Write-Verbose "Stop-RobocopyProcess: $($_.Exception.Message)"
    }
}
