#Requires -Version 5.1
<#
.SYNOPSIS
    Monitors the background robocopy process, rendering live UI and handling control.

.DESCRIPTION
    Per iteration it:
      1. Reads only the new COMPLETE log lines (Read-RobocopyLog); the offset is the
         only cursor, there is no partial-line buffer to carry around.
      2. Reconciles metrics through Add-EfcMetricsFromEntries (single source of truth).
      3. Renders one spinner/progress frame (Write-EfcSpinner).
      4. Polls a single non-blocking keystroke (Read-EfcKeyCommand) and applies
         Pause/Resume/Abort intents.
      5. Persists a throttled checkpoint (Write-EfcState).
      6. Yields briefly (Start-Sleep).

    Guarantees (regression-tested in tests/Unit/PauseResume.Tests.ps1):
      * Abort always leaves the loop - including Abort while paused - and the final
        status stays 'Aborted'.
      * If the loop is left by an error or Ctrl+C, the robocopy child is stopped
        (never orphaned) and the state is persisted as 'Aborted'.
      * Rate/ETA are computed from THIS run's bytes and ACTIVE (non-paused) time,
        so they stay correct after a resume or a pause.

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
    $aborted        = $false
    $cleanExit      = $false
    $pausedAt       = $null
    $pausedSeconds  = [double]0

    # Baselines: on a resumed job the metrics are cumulative, but the clock restarts.
    $baseBytes   = [long]$State.metrics.bytesCopied
    $baseElapsed = [long]$State.metrics.elapsedSeconds

    Write-Host ''
    Write-Host 'Transfer running. Controls: [P]ause  [R]esume  [A]bort' -ForegroundColor DarkGray
    Write-Host ''

    try {
        while ($true) {
            $processExited = $Process.HasExited

            # --- 1. Non-blocking delta read (skip while soft-paused) -----------
            if (-not $isPaused) {
                $delta = Read-RobocopyLog `
                    -LogPath $logPath `
                    -ByteOffset $State.logPointer.logByteOffset

                $State.logPointer.logByteOffset = $delta.NewByteOffset

                # --- 2. Metrics reconciliation ---------------------------------
                if (@($delta.Entries).Count -gt 0) {
                    Add-EfcMetricsFromEntries -State $State -Entries @($delta.Entries)
                }

                $elapsed = ([datetime]::UtcNow - $startTime).TotalSeconds
                $active  = [Math]::Max([double]0, $elapsed - $pausedSeconds)
                $State.metrics.elapsedSeconds = $baseElapsed + [long]$elapsed

                $runBytes = [long]$State.metrics.bytesCopied - $baseBytes
                if ($active -gt 0) {
                    $State.metrics.bytesPerSecond = [long]($runBytes / $active)
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

            # --- 3. Render one UI frame ---------------------------------------
            Write-EfcSpinner -State $State -PausedIndicator:$isPaused

            # --- 4. Non-blocking control keystroke ----------------------------
            $command = Read-EfcKeyCommand
            switch ($command) {
                'Pause' {
                    if (-not $isPaused) {
                        $suspended = Suspend-EfcProcess -ProcessId $State.robocopy.processId -Action Suspend
                        $isPaused  = $true
                        $pausedAt  = [datetime]::UtcNow
                        $State.control.requestedState    = 'Paused'
                        $State.control.pauseRequestedUtc = [datetime]::UtcNow.ToString('o')
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
                        if ($pausedAt) {
                            $pausedSeconds += ([datetime]::UtcNow - $pausedAt).TotalSeconds
                            $pausedAt = $null
                        }
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
                        $isPaused = $false      # a paused loop can never reach its exit condition
                        $pausedAt = $null
                    }
                    Stop-RobocopyProcess -Process $Process
                    $State.status = 'Aborted'
                    $aborted      = $true
                }
            }

            # `break` inside a switch only leaves the switch, so Abort is handled
            # with a flag that is honoured here, in the loop body.
            if ($aborted) { break }

            # --- 5. Throttled checkpoint persistence --------------------------
            $sinceCheckpoint = ([datetime]::UtcNow - $lastCheckpoint).TotalSeconds
            if ($sinceCheckpoint -ge $State.resumption.checkpointIntervalSeconds) {
                $State.resumption.lastCheckpointUtc = [datetime]::UtcNow.ToString('o')
                Write-EfcState -State $State -StateRoot $StateRoot
                $lastCheckpoint = [datetime]::UtcNow
            }

            # --- 6. Exit condition: process gone -> deterministic drain --------
            if ($processExited -and -not $isPaused) {
                # robocopy may flush trailing bytes AFTER HasExited flips true.
                # Sleep FIRST (even on the first pass), then read until the offset
                # stops advancing, otherwise the last batch would be lost.
                $drainStable = $false
                $drainGuard  = 0

                while (-not $drainStable -and $drainGuard -lt 200) {
                    Start-Sleep -Milliseconds 25

                    $tail = Read-RobocopyLog `
                        -LogPath $logPath `
                        -ByteOffset $State.logPointer.logByteOffset

                    $advanced = ($tail.NewByteOffset -ne $State.logPointer.logByteOffset)
                    $State.logPointer.logByteOffset = $tail.NewByteOffset

                    if (@($tail.Entries).Count -gt 0) {
                        Add-EfcMetricsFromEntries -State $State -Entries @($tail.Entries)
                    }

                    if (-not $advanced -and @($tail.Entries).Count -eq 0) {
                        $drainStable = $true
                    }
                    $drainGuard++
                }

                break
            }

            # --- 7. Cooperative yield -----------------------------------------
            Start-Sleep -Milliseconds $PollIntervalMs
        }

        $cleanExit = $true
    }
    finally {
        if (-not $cleanExit) {
            # Terminating error or Ctrl+C: never leave an orphaned robocopy
            # writing to the destination, and leave a resumable state behind.
            try {
                if (-not $Process.HasExited) {
                    if ($isPaused) {
                        [void] (Suspend-EfcProcess -ProcessId $State.robocopy.processId -Action Resume)
                    }
                    Stop-RobocopyProcess -Process $Process
                }
                $State.status = 'Aborted'
                $State.history += [pscustomobject]@{
                    event = 'Interrupted'; timestampUtc = [datetime]::UtcNow.ToString('o')
                    detail = 'Watch loop left abnormally (error or Ctrl+C); robocopy stopped.'
                }
                Write-EfcState -State $State -StateRoot $StateRoot
            }
            catch {
                Write-Verbose "Watch cleanup failed: $($_.Exception.Message)"
            }
        }
    }

    # --- Finalize ------------------------------------------------------------
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
