#Requires -Version 5.1
<#
.SYNOPSIS
    Reconciles an existing state.json against the current job request.

.DESCRIPTION
    Compares persisted source/destination signatures with the incoming request and
    determines the correct resumption posture:
      - Resume       : signatures match, job incomplete, not forced -> continue.
      - ForceRestart : -Force supplied -> discard old state, start clean.
      - Conflict     : signatures differ from an active job -> refuse unless -Force.
      - FreshStart   : no prior state -> brand new job.
    Also validates that the resume pointer references an intact line boundary.

.PARAMETER ExistingState
    The deserialized prior state (or $null for a fresh run).

.PARAMETER SourcePath
    The requested source path.

.PARAMETER DestinationPath
    The requested destination path.

.PARAMETER Force
    When set, always resolves to ForceRestart regardless of prior state.

.OUTPUTS
    PSCustomObject: Decision, Reason, ResumeByteOffset, ResumePartialBuffer.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Resolve-EfcResumption {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [pscustomobject] $ExistingState,
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [switch] $Force
    )

    Set-StrictMode -Version Latest

    $requestSourceSig = Get-EfcSignature -Path $SourcePath
    $requestDestSig   = Get-EfcSignature -Path $DestinationPath
    $requestKey       = '{0}-{1}' -f $requestSourceSig.Hash.Substring(0, 8),
                                       $requestDestSig.Hash.Substring(0, 8)

    $decision      = 'FreshStart'
    $reason        = 'No prior state found; starting a new job.'
    $resumeOffset  = [long]0
    $resumePartial = ''

    if ($Force) {
        return [pscustomobject]@{
            Decision            = 'ForceRestart'
            Reason              = 'Force requested; discarding any prior state.'
            ResumeByteOffset    = [long]0
            ResumePartialBuffer = ''
        }
    }

    if ($null -ne $ExistingState) {
        $existingKey = $ExistingState.signatures.combinedKey

        if ($existingKey -eq $requestKey) {
            # Same job identity. Decide based on completion status.
            if ($ExistingState.status -eq 'Completed') {
                $decision = 'AlreadyCompleted'
                $reason   = 'Matching job already completed; nothing to resume.'
            }
            else {
                # Validate the resume pointer references an intact line boundary.
                $offset  = [long]$ExistingState.logPointer.logByteOffset
                $partial = [string]$ExistingState.logPointer.partialLineBuffer
                $logPath = $ExistingState.robocopy.logPath

                $pointerValid = Test-EfcResumePointer -LogPath $logPath -ByteOffset $offset

                if ($pointerValid) {
                    $decision      = 'Resume'
                    $reason        = "Matching incomplete job found; resuming at byte offset $offset."
                    $resumeOffset  = $offset
                    $resumePartial = $partial
                }
                else {
                    # Pointer drift/corruption: safest is a differential restart.
                    # Robocopy will skip already-copied identical files anyway.
                    $decision      = 'DifferentialRestart'
                    $reason        = 'Resume pointer invalid; restarting with robocopy differential (identical files skipped).'
                    $resumeOffset  = [long]0
                    $resumePartial = ''
                }
            }
        }
        else {
            # A different job occupies the state slot.
            $decision = 'Conflict'
            $reason   = "Existing state targets a different source/destination pair (key '$existingKey' vs '$requestKey'). Use -Force to override."
        }
    }

    return [pscustomobject]@{
        Decision            = $decision
        Reason              = $reason
        ResumeByteOffset    = $resumeOffset
        ResumePartialBuffer = $resumePartial
    }
}
