#Requires -Version 5.1
<#
.SYNOPSIS
    Renders the final job summary and the safe-to-delete notification.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Write-EfcSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $State
    )

    Write-Host ''
    Write-Host '======================================================' -ForegroundColor DarkGray
    Write-Host (' Escape From Corporate - Job {0}' -f $State.status) -ForegroundColor White
    Write-Host '======================================================' -ForegroundColor DarkGray
    Write-Host (' Files copied : {0:N0} / {1:N0}' -f $State.metrics.filesCopied, $State.metrics.totalFilesExpected)
    Write-Host (' Bytes copied : {0}' -f (Format-EfcBytes -Bytes $State.metrics.bytesCopied))
    Write-Host (' Failures     : {0:N0}' -f $State.metrics.filesFailed)
    Write-Host (' Robocopy exit: {0}' -f $State.robocopy.exitCode)

    if ($State.validation.safeToDeleteSource) {
        Write-Host ''
        Write-Host ' VALIDATION PASSED - Source files are SAFE TO DELETE.' -ForegroundColor Green

        # Surface the hashing detail when sampled verification was performed.
        $sampleCount = 0
        if ($State.validation.PSObject.Properties.Name -contains 'sampleHashCount') {
            $sampleCount = [int]$State.validation.sampleHashCount
        }
        if ($sampleCount -gt 0) {
            Write-Host (' Method: {0} ({1} file(s) hash-verified, {2} mismatch(es)).' -f
                $State.validation.method,
                $State.validation.hashSamplesChecked,
                $State.validation.hashMismatches) -ForegroundColor Green
        }
        else {
            Write-Host (' Method: {0}.' -f $State.validation.method) -ForegroundColor Green
        }
        Write-Host ' Verify the destination before removing anything.' -ForegroundColor Green
    }
    elseif ($State.status -eq 'ValidationFailed') {
        Write-Host ''
        Write-Host (' VALIDATION FAILED - {0} mismatch(es). Do NOT delete the source.' -f
            $State.validation.mismatchCount) -ForegroundColor Red
    }
    elseif ($State.status -eq 'Aborted') {
        Write-Host ''
        Write-Host ' Job aborted. State saved; re-run to resume.' -ForegroundColor Yellow
    }
    Write-Host ''
}
