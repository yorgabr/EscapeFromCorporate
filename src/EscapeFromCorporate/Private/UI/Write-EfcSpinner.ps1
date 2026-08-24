#Requires -Version 5.1
<#
.SYNOPSIS
    Renders a single frame of the efc activity spinner plus live progress metrics.

.DESCRIPTION
    Frame-based spinner intended to be called once per watch-loop iteration. It
    advances a module-scoped frame index and rewrites a single console status line
    in place using cursor positioning, avoiding full-screen redraws. Degrades
    gracefully to periodic linear Write-Host when no interactive raw UI is present
    (e.g. CI, redirected output, ISE).

.PARAMETER State
    The live job state object supplying metrics.

.PARAMETER PausedIndicator
    When set, renders a paused glyph instead of the animated spinner frame.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>

# Script-scoped spinner state, initialized eagerly at import time. Under
# Set-StrictMode -Version Latest (active at the module's defining scope),
# reading a $script: variable that was never assigned throws "A variável
# '...' não pode ser recuperada porque ainda não foi definida" - even inside
# `if (-not $var)`. This is the same root cause fixed earlier in
# ConvertFrom-RobocopyLine.ps1 ($script:EfcRxNewFile) and
# Suspend-EfcProcess.ps1 ($script:EfcNtdllLoaded); it simply hadn't been
# exercised yet here because the watch loop used to fail upstream first.
$script:EfcSpinnerFrames   = $null
$script:EfcSpinnerIndex    = 0
$script:EfcLastLinearWrite = [datetime]::MinValue

function Write-EfcSpinner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State,

        [switch] $PausedIndicator
    )

    Set-StrictMode -Version Latest

    if (-not $script:EfcSpinnerFrames) {
        # ASCII-only frames for maximum console/codepage compatibility.
        $script:EfcSpinnerFrames = @('|', '/', '-', '\')
        $script:EfcSpinnerIndex  = 0
    }

    $m = $State.metrics

    # Compute a human-readable status segment.
    $pct     = [Math]::Min(100, [Math]::Round($m.percentComplete, 1))
    $etaSpan = [TimeSpan]::FromSeconds([Math]::Max(0, $m.etaSeconds))
    $rate    = Format-EfcBytes -Bytes $m.bytesPerSecond
    $done    = Format-EfcBytes -Bytes $m.bytesCopied
    $total   = Format-EfcBytes -Bytes $m.totalBytesExpected

    if ($PausedIndicator) {
        $glyph = '[||]'
    }
    else {
        $glyph = $script:EfcSpinnerFrames[$script:EfcSpinnerIndex]
        $script:EfcSpinnerIndex =
            ($script:EfcSpinnerIndex + 1) % $script:EfcSpinnerFrames.Count
    }

    $line = ('{0} {1,5}% | {2}/{3} | {4}/s | files {5:N0}/{6:N0} | ETA {7:hh\:mm\:ss}' -f
        $glyph, $pct, $done, $total, $rate,
        $m.filesCopied, $m.totalFilesExpected, $etaSpan)

    # --- Interactive path: rewrite the status line in place --------------------
    if (Test-EfcInteractiveHost) {
        try {
            $raw = $Host.UI.RawUI
            $y   = $raw.CursorPosition.Y
            [Console]::SetCursorPosition(0, $y)
            # Pad to clear any residual characters from a longer previous frame.
            $padded = $line.PadRight([Math]::Max($line.Length, $raw.BufferSize.Width - 1))
            [Console]::Write($padded)
            [Console]::SetCursorPosition(0, $y)
        }
        catch {
            # Cursor ops can fail on odd hosts; fall back silently.
            Write-Host $line
        }
    }
    else {
        # --- Non-interactive: throttle linear output to avoid log spam ---------
        if (([datetime]::UtcNow - $script:EfcLastLinearWrite).TotalSeconds -ge 5) {
            Write-Host $line
            $script:EfcLastLinearWrite = [datetime]::UtcNow
        }
    }
}