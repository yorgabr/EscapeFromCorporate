#Requires -Version 5.1
<#
.SYNOPSIS
    Validates that a completed copy is an exact match between source and destination.

.DESCRIPTION
    Performs a differential verification using 'robocopy /L' (list-only): after a
    successful transfer, a second list pass should report ZERO pending files, since
    every source file must already exist identically at the destination. Any file
    robocopy still lists as needing copy is counted as a mismatch.

    Optionally performs sampled SHA256 hashing of a subset of files for deeper
    assurance on critical transfers, without the cost of hashing every file in a
    tens-of-gigabytes tree.

.PARAMETER SourcePath
    Absolute source directory.

.PARAMETER DestinationPath
    Destination directory (local or UNC).

.PARAMETER SampleHashCount
    Number of files to sample for SHA256 comparison. 0 disables hashing (default).

.PARAMETER RobocopyRunner
    Injectable list-pass runner for testing. Signature: { param($Source,$Dest) -> string[] }

.OUTPUTS
    PSCustomObject: Method, MismatchCount, HashSamplesChecked, HashMismatches.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Test-EfcCopyIntegrity {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [ValidateRange(0, 10000)] [int] $SampleHashCount = 0,
        [scriptblock] $RobocopyRunner
    )

    Set-StrictMode -Version Latest

    if (-not $RobocopyRunner) {
        $RobocopyRunner = {
            param($Source, $Dest)
            $robo = Join-Path $env:SystemRoot 'System32\robocopy.exe'
            # A post-copy list pass: any listed file == still-pending == mismatch.
            & $robo $Source $Dest /L /E /BYTES /NJH /NJS /NC /TS /R:0 /W:0 2>&1
        }
    }

    $lines        = & $RobocopyRunner $SourcePath $DestinationPath
    $mismatchCount = 0

    foreach ($line in $lines) {
        $entry = ConvertFrom-RobocopyLine -Line ([string]$line)
        if ($entry -and $entry.Type -eq 'File') {
            $mismatchCount++
        }
    }

    # --- Optional sampled hashing ---------------------------------------------
    $samplesChecked = 0
    $hashMismatches = 0
    $method         = 'RobocopyDifferentialList'

    if ($SampleHashCount -gt 0 -and (Test-Path -LiteralPath $SourcePath)) {
        $method = 'RobocopyList+SampledSHA256'

        # Resolve a canonical, separator-normalized base path so the relative-path
        # slice is robust against trailing separators and casing differences
        # between the supplied path and Get-ChildItem's FullName.
        $sourceBase = (Resolve-Path -LiteralPath $SourcePath).ProviderPath.TrimEnd('\')
        $baseLength = $sourceBase.Length

        $allFiles = @(Get-ChildItem -LiteralPath $sourceBase -Recurse -File -ErrorAction SilentlyContinue)
        if ($allFiles.Count -gt 0) {
            $take        = [Math]::Min($SampleHashCount, $allFiles.Count)
            $sourceFiles = $allFiles | Get-Random -Count $take

            foreach ($sf in @($sourceFiles)) {
                # StartsWith guard: skip anything that is not under the base (defensive).
                if (-not $sf.FullName.StartsWith($sourceBase, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $relative = $sf.FullName.Substring($baseLength).TrimStart('\')
                $destFile = Join-Path $DestinationPath $relative

                $samplesChecked++

                if (-not (Test-Path -LiteralPath $destFile)) {
                    $hashMismatches++
                    continue
                }

                $srcHash = (Get-FileHash -LiteralPath $sf.FullName -Algorithm SHA256).Hash
                $dstHash = (Get-FileHash -LiteralPath $destFile   -Algorithm SHA256).Hash
                if ($srcHash -ne $dstHash) { $hashMismatches++ }
            }
        }
    }

    return [pscustomobject]@{
        Method             = $method
        MismatchCount      = $mismatchCount + $hashMismatches
        HashSamplesChecked = $samplesChecked
        HashMismatches     = $hashMismatches
    }
}
