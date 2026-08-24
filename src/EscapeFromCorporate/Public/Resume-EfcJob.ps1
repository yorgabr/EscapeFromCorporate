#Requires -Version 5.1
<#
.SYNOPSIS
    Resumes an interrupted efc job from its persisted state.

.DESCRIPTION
    Convenience wrapper that reads the persisted state and re-invokes Invoke-EfcJob
    using the stored source/destination signatures, continuing from the last
    checkpoint offset. Fails if no resumable state exists.

.PARAMETER StateRoot
    Override for the state directory.

.EXAMPLE
    Resume-EfcJob

    Resumes the most recent interrupted transfer.

.OUTPUTS
    PSCustomObject final job state.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Resume-EfcJob {
    <#
    .EXTERNALHELP EscapeFromCorporate-help.xml
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $StateRoot = (Join-Path $env:LOCALAPPDATA 'EscapeFromCorporate')
    )

    Set-StrictMode -Version Latest

    $state = Get-EfcState -StateRoot $StateRoot
    if (-not $state) {
        throw 'No persisted job state found; nothing to resume.'
    }
    if ($state.status -eq 'Completed') {
        Write-Host 'Job already completed; nothing to resume.' -ForegroundColor Green
        return $state
    }

    Write-Verbose "Resuming job $($state.jobId) from offset $($state.logPointer.logByteOffset)."
    return Invoke-EfcJob -Source $state.signatures.source.path `
        -Destination $state.signatures.destination.path -StateRoot $StateRoot
}
