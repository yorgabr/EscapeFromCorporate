#Requires -Version 5.1
<#
.SYNOPSIS
    Monitors the background robocopy process, rendering live UI and handling control.

.DESCRIPTION
    The heart of the interactive layer. Per iteration it:
      1. Reads only the new log delta (Read-RobocopyLog), never re-reading bytes.
      2. Reconciles metrics (files, bytes, rate, ETA) from parsed entries.
      3. Renders one spinner/progress frame (Write-EfcSpinner).
      4. Polls a single non-blocking keystroke (Read-EfcKeyCommand) and applies
         Pause/Resume/Abort intents.
      5. Persists a throttled checkpoint (Write-EfcState) at the configured interval.
      6. Yields briefly (Start-Sleep) to keep CPU low and the console responsive.

    The loop never performs a blocking WaitForExit; it exits when the process has
    exited AND the trailing log delta has been drained.

.PARAMETER Process
    The started [System.Diagnostics.Process] handle.

.PARAMETER State
    The live job state object.

.PARAMETER StateRoot
    State directory for checkpoint persistence.

.PARAMETER PollIntervalMs
    Loop cadence in milliseconds. Defaults to 200ms.

.OUTPUTS
    The mutated/final state object (with robocopy.exitCode populated).

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Watch-RobocopyProcess {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Process,
        [Parameter(Mandatory)] [pscustomobject] $State,
        [Parameter(Mandatory)] [string] $StateRoot,
        [int] $PollIntervalMs = 200
    )

    Set-StrictMode -Version Latest

    $logPath        = $State.robocopy.logPath
    $lastCheckpoint = [datetime]::UtcNow
    $startTime      = [datetime]::UtcNow
    $isPaused       = $false

    Write-Host ''
    Write-Host 'Transfer running. Controls: [P]ause  [R]esume  [A]bort' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        $processExited = $Process.HasExited

        # --- 1. Non-blocking delta read (skip while soft-paused) ---------------
        if (-not $isPaused) {
            $delta = Read-RobocopyLog `
                -LogPath $logPath `
                -ByteOffset $State.logPointer.logByteOffset `
                -PartialLineBuffer $State.logPointer.partialLineBuffer

            $State.logPointer.logByteOffset     = $delta.NewByteOffset
            $State.logPointer.partialLineBuffer = $delta.PartialLineBuffer

            # --- 2. Metrics reconciliation -------------------------------------
            foreach ($entry in $delta.Entries) {
                switch ($entry.Type) {
                    'File'  { $State.metrics.filesCopied++;  $State.metrics.bytesCopied += $entry.Size }
                    'Dir'   { $State.metrics.dirsCreated++ }
                    'Error' { $State.metrics.filesFailed++ }
                }
            }

            $elapsed = ([datetime]::UtcNow - $startTime).TotalSeconds
            $State.metrics.elapsedSeconds = [long]$elapsed

            if ($elapsed -gt 0) {
                $State.metrics.bytesPerSecond = [long]($State.metrics.bytesCopied / $elapsed)
            }
            if ($State.metrics.totalBytesExpected -gt 0) {
                $State.metrics.percentComplete =
                    [double]($State.metrics.bytesCopied / $State.metrics.totalBytesExpected * 100)

                $remaining = $State.metrics.totalBytesExpected - $State.metrics.bytesCopied
                if ($State.metrics.bytesPerSecond -gt 0) {
                    $State.metrics.etaSeconds = [long]($remaining / $State.metrics.bytesPerSecond)
                }
            }
        }

        # --- 3. Render one UI frame -------------------------------------------
        Write-EfcSpinner -State $State -PausedIndicator:$isPaused

        # --- 4. Non-blocking control keystroke --------------------------------
        $command = Read-EfcKeyCommand
        switch ($command) {
            'Pause' {
                if (-not $isPaused) {
                    $suspended = Suspend-EfcProcess -ProcessId $State.robocopy.processId -Action Suspend
                    $isPaused  = $true
                    $State.control.requestedState    = 'Paused'
                    $State.control.pauseRequestedUtc  = [datetime]::UtcNow.ToString('o')
                    $State.status = 'Paused'
                    Write-Host ''
                    Write-Host ('Paused ({0}). Press [R] to resume.' -f
                        ($(if ($suspended) { 'process suspended' } else { 'soft-pause' }))) -ForegroundColor Yellow
                }
            }
            'Resume' {
                if ($isPaused) {
                    [void] (Suspend-EfcProcess -ProcessId $State.robocopy.processId -Action Resume)
                    $isPaused = $false
                    $State.control.requestedState = 'Running'
                    $State.control.resumeCount++
                    $State.status = 'Running'
                    Write-Host ''
                    Write-Host 'Resumed.' -ForegroundColor Green
                }
            }
            'Abort' {
                Write-Host ''
                Write-Host 'Abort requested. Stopping transfer...' -ForegroundColor Red
                $State.control.abortRequested = $true
                if ($isPaused) {
                    [void] (Suspend-EfcProcess -ProcessId $State.robocopy.processId -Action Resume)
                }
                Stop-RobocopyProcess -Process $Process
                $State.status = 'Aborted'
                break
            }
        }

        # --- 5. Throttled checkpoint persistence ------------------------------
        $sinceCheckpoint = ([datetime]::UtcNow - $lastCheckpoint).TotalSeconds
        if ($sinceCheckpoint -ge $State.resumption.checkpointIntervalSeconds) {
            $State.resumption.lastCheckpointUtc = [datetime]::UtcNow.ToString('o')
            Write-EfcState -State $State -StateRoot $StateRoot
            $lastCheckpoint = [datetime]::UtcNow
        }

        # --- 6. Exit condition: process gone -> enter deterministic drain ------
        if ($processExited -and -not $isPaused) {
            # Robocopy may flush trailing bytes AFTER HasExited flips true, because
            # the /LOG buffer is released on teardown. We must drain until the log
            # offset stabilizes across consecutive reads, otherwise the final batch
            # of files would be lost from the metrics.
            #
            # IMPORTANT: the brief sleep runs FIRST, on every iteration including
            # the very first one. A flush can land in the narrow window between
            # HasExited flipping true and our very first drain read; sleeping
            # before that first read (not only between subsequent ones) is what
            # actually gives robocopy the window to finish writing. Checking
            # stability immediately, with no wait at all, would silently drop a
            # flush that hasn't happened yet - which is precisely the race this
            # loop exists to close.
            $drainStable = $false
            $drainGuard  = 0   # hard cap to prevent a pathological infinite drain

            while (-not $drainStable -and $drainGuard -lt 200) {
                # Give robocopy a brief window to flush any remaining buffer
                # BEFORE reading, not just between retries.
                Start-Sleep -Milliseconds 25

                $tail = Read-RobocopyLog `
                    -LogPath $logPath `
                    -ByteOffset $State.logPointer.logByteOffset `
                    -PartialLineBuffer $State.logPointer.partialLineBuffer

                $advanced = ($tail.NewByteOffset -ne $State.logPointer.logByteOffset)

                $State.logPointer.logByteOffset     = $tail.NewByteOffset
                $State.logPointer.partialLineBuffer = $tail.PartialLineBuffer

                if ($tail.Entries.Count -gt 0) {
                    Add-EfcMetricsFromEntries -State $State -Entries $tail.Entries
                }

                if (-not $advanced -and $tail.Entries.Count -eq 0) {
                    $drainStable = $true
                }

                $drainGuard++
            }

            break
        }

        # --- 7. Cooperative yield ---------------------------------------------
        Start-Sleep -Milliseconds $PollIntervalMs
    }

    # --- Finalize --------------------------------------------------------------
    if ($Process.HasExited) {
        $State.robocopy.exitCode = $Process.ExitCode
    }
    $State.history += [pscustomobject]@{
        event = 'ProcessEnded'; timestampUtc = [datetime]::UtcNow.ToString('o')
        detail = "Exit code $($State.robocopy.exitCode); status $($State.status)"
    }
    Write-EfcState -State $State -StateRoot $StateRoot

    Write-Host ''   # move cursor off the status line
    return $State
}