#Requires -Version 5.1
<#
.SYNOPSIS
    Validates that a persisted byte offset lands on an intact log line boundary.

.DESCRIPTION
    A safe resume requires the offset to be <= current log length and to sit exactly
    after a newline (or at EOF). If the log was truncated, rotated, or the offset
    drifted past the file end, the pointer is deemed invalid and the caller falls
    back to a differential restart.

.OUTPUTS
    [bool] indicating whether the pointer is safe to resume from.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Test-EfcResumePointer {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [long]   $ByteOffset
    )

    Set-StrictMode -Version Latest

    if ($ByteOffset -eq 0) { return $true }               # start-of-file is always valid
    if (-not (Test-Path -LiteralPath $LogPath)) { return $false }

    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new(
            $LogPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)

        if ($ByteOffset -gt $stream.Length) { return $false }  # offset past EOF -> drift
        if ($ByteOffset -eq $stream.Length) { return $true }   # exactly at EOF -> valid

        # Inspect the byte immediately preceding the offset: must be a newline (0x0A).
        [void] $stream.Seek($ByteOffset - 1, [System.IO.SeekOrigin]::Begin)
        $prevByte = $stream.ReadByte()

        return ($prevByte -eq 0x0A)   # LF confirms a clean line boundary
    }
    catch {
        return $false
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}
