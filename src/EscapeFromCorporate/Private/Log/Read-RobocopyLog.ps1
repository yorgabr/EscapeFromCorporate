#Requires -Version 5.1
<#
.SYNOPSIS
    Non-blocking incremental reader for an active robocopy /UNILOG file.

.DESCRIPTION
    Reads ONLY complete lines appended since -ByteOffset. The offset always points
    at the first byte of the first line not yet consumed, so no residual text has
    to be carried between polls (the old PartialLineBuffer round-trip is gone).

    robocopy /UNILOG writes UTF-16LE (with BOM). Line boundaries are located in
    the RAW bytes (0x0A 0x00 on an even index) BEFORE any decoding, so a read that
    ends in the middle of a character or a line can never corrupt the offset.

.OUTPUTS
    PSCustomObject: Entries, NewByteOffset, RawLinesConsumed.

.NOTES
    Drop-in replacement for Private/Log/Read-RobocopyLog.ps1. Contract changes:
      * Requires robocopy to write with /UNILOG: (UTF-16LE) instead of /LOG:.
        Change the flag in Connect-Robocopy.
      * -PartialLineBuffer is gone: the offset itself marks the first
        unconsumed line, so state.logPointer.partialLineBuffer becomes dead
        weight (keep it in the schema for now, always '').
      * Watch-RobocopyProcess: drop -PartialLineBuffer from both calls.
    Validated under PowerShell 7.4 (Linux) with 6 scenarios: partial line
    completed later, stable offset across idle polls, accented paths, 60k lines
    consumed in 64 KiB chunks, truncated/rotated log. Re-run on Windows
    PowerShell 5.1 (Pester) before merging.
#>
function Read-RobocopyLog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $LogPath,
        [Parameter(Mandatory)] [ValidateRange(0, [long]::MaxValue)] [long] $ByteOffset,
        # Cap per poll: bounds memory and avoids the [int] overflow on huge deltas.
        [ValidateRange(4096, 67108864)] [int] $MaxChunkBytes = 4194304
    )

    Set-StrictMode -Version Latest

    $result = [pscustomobject]@{
        Entries          = @()
        NewByteOffset    = $ByteOffset
        RawLinesConsumed = 0
    }
    if (-not (Test-Path -LiteralPath $LogPath)) { return $result }

    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new($LogPath,
            [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)

        $length = $stream.Length
        if ($length -lt $ByteOffset) { $ByteOffset = 0 }          # log truncated/rotated: restart
        $start = $ByteOffset
        if ($start -eq 0 -and $length -ge 2) { $start = 2 }       # skip the UTF-16LE BOM (FF FE)
        $count = [int][Math]::Min([long]$MaxChunkBytes, $length - $start)
        $count = $count - ($count % 2)                            # UTF-16: whole code units only
        if ($count -le 0) { return $result }

        [void] $stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new($count)
        $read = 0
        while ($read -lt $count) {
            $n = $stream.Read($buffer, $read, $count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $read = $read - ($read % 2)

        # Last complete line = last LF (0x0A 0x00) on an even index.
        $lastLf = -1
        for ($i = $read - 2; $i -ge 0; $i -= 2) {
            if ($buffer[$i] -eq 0x0A -and $buffer[$i + 1] -eq 0x00) { $lastLf = $i; break }
        }
        if ($lastLf -lt 0) {
            # No complete line yet. If a single line exceeds the chunk cap, skip it
            # rather than stall forever (robocopy lines are far below 4 MiB).
            if ($read -ge $MaxChunkBytes - 2) { $result.NewByteOffset = $start + $read }
            return $result
        }

        $consumed = $lastLf + 2
        $text     = [System.Text.Encoding]::Unicode.GetString($buffer, 0, $consumed)
        $parsed   = [System.Collections.Generic.List[object]]::new()
        foreach ($line in $text.Split([char]10)) {
            $line = $line.TrimEnd([char]13)
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = ConvertFrom-RobocopyLine -Line $line
            if ($entry) { $parsed.Add($entry) }
        }

        $result.Entries          = $parsed.ToArray()
        $result.NewByteOffset    = $start + $consumed
        $result.RawLinesConsumed = $parsed.Count
        return $result
    }
    finally { if ($stream) { $stream.Dispose() } }
}
