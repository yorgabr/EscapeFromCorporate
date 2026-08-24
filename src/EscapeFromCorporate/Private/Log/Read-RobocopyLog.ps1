#Requires -Version 5.1
<#
.SYNOPSIS
    Non-blocking incremental reader for an active robocopy log file.

.DESCRIPTION
    Opens the log via [System.IO.FileStream] with FileShare.ReadWrite so robocopy
    can keep writing while we read. Seeks to the persisted byte offset, reads only
    the new delta, isolates any trailing partial line, parses complete lines into
    structured entries, and returns the advanced byte offset plus residual buffer.

    This function performs a SINGLE poll pass. The watch loop (Phase 4) calls it
    repeatedly. It never blocks waiting for I/O and never re-reads consumed bytes.

.PARAMETER LogPath
    Path to the robocopy log file being polled.

.PARAMETER ByteOffset
    The persisted byte position (from state.logPointer.logByteOffset) to resume from.

.PARAMETER PartialLineBuffer
    Residual text from a previously incomplete line (state.logPointer.partialLineBuffer).

.OUTPUTS
    PSCustomObject with:
      Entries            : parsed structured records (array)
      NewByteOffset      : advanced offset over fully-consumed complete lines
      PartialLineBuffer  : leftover incomplete line to carry into next poll
      RawLinesConsumed   : count of complete lines processed this pass

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Read-RobocopyLog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LogPath,

        [Parameter(Mandatory)]
        [ValidateRange(0, [long]::MaxValue)]
        [long] $ByteOffset,

        [AllowEmptyString()]
        [string] $PartialLineBuffer = ''
    )

    Set-StrictMode -Version Latest

    # Robocopy logs in the console OEM/UTF8 code page; we standardize on UTF8.
    $encoding = [System.Text.Encoding]::UTF8

    $result = [pscustomobject]@{
        Entries           = @()
        NewByteOffset     = $ByteOffset
        PartialLineBuffer = $PartialLineBuffer
        RawLinesConsumed  = 0
    }

    if (-not (Test-Path -LiteralPath $LogPath)) {
        # Log not yet created by robocopy; nothing to consume this pass.
        return $result
    }

    $stream = $null
    try {
        # --- Non-blocking open: coexist with robocopy's write handle -----------
        $stream = [System.IO.FileStream]::new(
            $LogPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)

        $currentLength = $stream.Length

        # No growth since last poll -> return unchanged (idempotent).
        if ($currentLength -le $ByteOffset) {
            return $result
        }

        # --- Read ONLY the delta bytes -----------------------------------------
        [void] $stream.Seek($ByteOffset, [System.IO.SeekOrigin]::Begin)

        $deltaCount = [int]($currentLength - $ByteOffset)
        $buffer     = [byte[]]::new($deltaCount)
        $read       = $stream.Read($buffer, 0, $deltaCount)

        $deltaText  = $encoding.GetString($buffer, 0, $read)

        # --- Prepend residual partial line from the previous poll --------------
        $working = $PartialLineBuffer + $deltaText

        # Normalize CRLF -> LF for consistent splitting; keep byte accounting on raw.
        $normalized = $working -replace "`r`n", "`n"
        $segments   = $normalized -split "`n", -1   # -1 keeps trailing empty

        # The final segment is either an incomplete line or empty (if ended on \n).
        $lastIndex     = $segments.Count - 1
        $completeLines = @()
        if ($lastIndex -ge 1) {
            $completeLines = $segments[0..($lastIndex - 1)]
        }
        $newPartial = $segments[$lastIndex]

        # --- Parse complete lines ----------------------------------------------
        $parsed = [System.Collections.Generic.List[object]]::new()
        foreach ($line in $completeLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = ConvertFrom-RobocopyLine -Line $line
            if ($entry) { [void] $parsed.Add($entry) }
        }

        # --- Advance offset by BYTES of fully-consumed content -----------------
        # Authoritative formula: the new offset is the prior offset plus the delta
        # bytes read this pass, minus the bytes still held as the residual partial
        # line (which will be re-read next pass once completed). This stays
        # byte-accurate with multibyte UTF8 because $newPartialBytes is measured
        # via Encoding.GetByteCount, not character length.
        $newPartialBytes = $encoding.GetByteCount($newPartial)

        $result.Entries           = $parsed.ToArray()
        $result.NewByteOffset     = $ByteOffset + ($read - $newPartialBytes)
        $result.PartialLineBuffer = $newPartial
        $result.RawLinesConsumed  = $parsed.Count

        # Sanity clamp: never exceed the file length.
        if ($result.NewByteOffset -gt $currentLength) {
            $result.NewByteOffset = $currentLength
        }

        return $result
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}
