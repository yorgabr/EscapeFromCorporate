#Requires -Version 5.1
<#
.SYNOPSIS
    Non-blocking capture of a single runtime control keystroke (P/R/A).

.DESCRIPTION
    Polls [Console]::KeyAvailable first and only consumes a key when one is
    actually queued, so the watch loop never blocks waiting for input. Maps
    the P/R/A keys (case-insensitive) to their corresponding control intent;
    any other key, or no key at all, is ignored. On hosts without a real
    console (CI, redirected output, ISE), probing KeyAvailable can throw -
    this function treats that as "no key available" rather than propagating
    the error, matching the same graceful-degradation contract used by
    Test-EfcInteractiveHost.

.OUTPUTS
    [string] one of 'Pause', 'Resume', 'Abort', or $null when no relevant key
    was pressed (or the host has no interactive console).

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Read-EfcKeyCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Set-StrictMode -Version Latest

    try {
        if (-not [Console]::KeyAvailable) {
            return $null
        }

        # $true suppresses echoing the keypress to the console.
        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'P' { return 'Pause' }
            'R' { return 'Resume' }
            'A' { return 'Abort' }
            default { return $null }
        }
    }
    catch {
        # No real console (CI, redirected output, ISE) - treat as no keystroke.
        Write-Verbose "Read-EfcKeyCommand: console probe unavailable ($($_.Exception.Message))."
        return $null
    }
}