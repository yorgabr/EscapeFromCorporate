#Requires -Version 5.1
<#
.SYNOPSIS
    Deserializes the persisted efc job state from LOCALAPPDATA.

.DESCRIPTION
    Reads and validates state.json. Returns $null when no state exists (fresh run).
    Performs schema-version tolerance and guards against corrupt/partial JSON left
    by an abrupt process kill, in which case it attempts the sidecar temp file.

.PARAMETER StateRoot
    Override for the state directory. Defaults to
    $env:LOCALAPPDATA\EscapeFromCorporate. Injectable for testing.

.OUTPUTS
    PSCustomObject representing the state, or $null when absent.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Get-EfcState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $StateRoot = (Join-Path $env:LOCALAPPDATA 'EscapeFromCorporate')
    )

    Set-StrictMode -Version Latest

    $statePath = Join-Path $StateRoot 'state.json'
    $tempPath  = "$statePath.tmp"

    if (-not (Test-Path -LiteralPath $statePath)) {
        # A crash mid-rename may have left only the temp file. Try to salvage it.
        if (Test-Path -LiteralPath $tempPath) {
            Write-Verbose "Primary state absent; attempting recovery from temp sidecar."
            $statePath = $tempPath
        }
        else {
            return $null
        }
    }

    try {
        $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

        $state = $raw | ConvertFrom-Json -ErrorAction Stop

        if (-not $state.schemaVersion) {
            Write-Warning "State file lacks schemaVersion; treating as invalid."
            return $null
        }

        return $state
    }
    catch {
        Write-Warning "State file is corrupt or unreadable: $($_.Exception.Message)"
        return $null
    }
}
