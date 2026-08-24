#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the persisted efc job state (and optionally its logs).

.DESCRIPTION
    Deletes state.json and its sidecar files. With -IncludeLogs, also purges the logs
    directory. Supports -WhatIf/-Confirm via ShouldProcess. Use before starting an
    unrelated job or to reclaim space after a validated, deleted transfer.

.PARAMETER StateRoot
    Override for the state directory.

.PARAMETER IncludeLogs
    Also remove the logs subdirectory.

.EXAMPLE
    Clear-EfcState

    Removes the current state file after confirmation.

.EXAMPLE
    Clear-EfcState -IncludeLogs -Confirm:$false

    Purges state and logs without prompting.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Clear-EfcState {
    <#
    .EXTERNALHELP EscapeFromCorporate-help.xml
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string] $StateRoot = (Join-Path $env:LOCALAPPDATA 'EscapeFromCorporate'),
        [switch] $IncludeLogs
    )

    Set-StrictMode -Version Latest

    foreach ($name in 'state.json', 'state.json.tmp', 'state.json.bak') {
        $p = Join-Path $StateRoot $name
        if ((Test-Path -LiteralPath $p) -and $PSCmdlet.ShouldProcess($p, 'Remove')) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }
    }

    if ($IncludeLogs) {
        $logs = Join-Path $StateRoot 'logs'
        if ((Test-Path -LiteralPath $logs) -and $PSCmdlet.ShouldProcess($logs, 'Remove logs')) {
            Remove-Item -LiteralPath $logs -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
