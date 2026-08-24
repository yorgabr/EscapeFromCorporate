#Requires -Version 5.1
<#
.SYNOPSIS
    Atomically serializes the efc job state to LOCALAPPDATA.

.DESCRIPTION
    Writes state.json using a temp-then-replace strategy so a mid-write crash never
    leaves a truncated primary file. The updatedUtc stamp is refreshed on every call.
    Uses [System.IO.File]::Replace when a prior file exists (atomic on NTFS), else a
    plain move.

.PARAMETER State
    The state object to persist (PSCustomObject).

.PARAMETER StateRoot
    Override for the state directory. Injectable for testing.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Write-EfcState {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject] $State,

        [string] $StateRoot = (Join-Path $env:LOCALAPPDATA 'EscapeFromCorporate')
    )

    Set-StrictMode -Version Latest

    if (-not (Test-Path -LiteralPath $StateRoot)) {
        New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    }

    $statePath   = Join-Path $StateRoot 'state.json'
    $tempPath    = "$statePath.tmp"
    $backupPath  = "$statePath.bak"

    # Refresh the mutation timestamp on every persist.
    $State.updatedUtc = [datetime]::UtcNow.ToString('o')

    if (-not $PSCmdlet.ShouldProcess($statePath, 'Persist efc state')) { return }

    # Serialize to the temp sidecar first.
    $json = $State | ConvertTo-Json -Depth 10
    # UTF8 without BOM keeps byte accounting consistent with the log reader layer.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)

    if (Test-Path -LiteralPath $statePath) {
        # Atomic swap on NTFS; backup lets Get-EfcState recover on partial failure.
        [System.IO.File]::Replace($tempPath, $statePath, $backupPath)
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        [System.IO.File]::Move($tempPath, $statePath)
    }
}
