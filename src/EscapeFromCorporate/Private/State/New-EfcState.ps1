#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstraps a fresh efc state object conforming to schemaVersion 1.0.0.

.DESCRIPTION
    Produces the canonical state skeleton (Phase 1 schema) with computed source/
    destination signatures and a new jobId. Metrics are zeroed; the pre-flight
    engine later fills totalFilesExpected/totalBytesExpected.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function New-EfcState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [Parameter(Mandatory)] [string] $LogPath
    )

    Set-StrictMode -Version Latest

    $sourceSig = Get-EfcSignature -Path $SourcePath
    $destSig   = Get-EfcSignature -Path $DestinationPath
    $nowUtc    = [datetime]::UtcNow.ToString('o')

    return [pscustomobject]@{
        schemaVersion = '1.1.0'
        jobId         = [guid]::NewGuid().ToString()
        createdUtc    = $nowUtc
        updatedUtc    = $nowUtc
        status        = 'Created'

        signatures = [pscustomobject]@{
            source = [pscustomobject]@{
                path           = $sourceSig.Path
                normalizedPath = $sourceSig.NormalizedPath
                hash           = $sourceSig.Hash
            }
            destination = [pscustomobject]@{
                path           = $destSig.Path
                normalizedPath = $destSig.NormalizedPath
                hash           = $destSig.Hash
            }
            combinedKey = '{0}-{1}' -f $sourceSig.Hash.Substring(0, 8),
                                        $destSig.Hash.Substring(0, 8)
        }

        robocopy = [pscustomobject]@{
            processId   = $null
            commandLine = $null
            flags       = @()
            logPath     = $LogPath
            startedUtc  = $null
            exitCode    = $null
        }

        logPointer = [pscustomobject]@{
            logByteOffset       = [long]0
            lastConsumedLineHash = $null
            encoding            = 'UTF8'
            partialLineBuffer   = ''
        }

        metrics = [pscustomobject]@{
            totalBytesExpected  = [long]0
            bytesCopied         = [long]0
            totalFilesExpected  = [long]0
            filesCopied         = [long]0
            filesSkipped        = [long]0
            filesFailed         = [long]0
            dirsCreated         = [long]0
            percentComplete     = [double]0
            bytesPerSecond      = [long]0
            etaSeconds          = [long]0
            elapsedSeconds      = [long]0
        }

        control = [pscustomobject]@{
            requestedState    = 'Running'
            pauseRequestedUtc = $null
            resumeCount       = 0
            abortRequested    = $false
        }

        resumption = [pscustomobject]@{
            isResumable               = $true
            resumeStrategy            = 'RobocopyRestartable'
            lastCheckpointUtc         = $nowUtc
            checkpointIntervalSeconds = 15
        }

        validation = [pscustomobject]@{
            performed          = $false
            method             = $null
            mismatchCount      = $null
            validatedUtc       = $null
            safeToDeleteSource = $false
            sampleHashCount    = 0
            hashSamplesChecked = 0
            hashMismatches     = 0
        }

        history = @(
            [pscustomobject]@{
                event        = 'JobCreated'
                timestampUtc = $nowUtc
                detail       = 'New job bootstrapped'
            }
        )
    }
}
