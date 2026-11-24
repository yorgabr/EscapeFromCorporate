#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies that a completed copy is an exact match between source and destination.

.DESCRIPTION
    The verdict is taken from robocopy's EXIT CODE on a list-only pass (/L), which
    is locale-independent and does not depend on parsing human-readable output:

        0  nothing would be copied, no differences           -> identical
        1  at least one file would be copied                 -> DIVERGENT
        2  extra files/dirs at the destination               -> ignored (no purge)
        4  mismatched files/dirs (type clash)                -> DIVERGENT
        8  failures (could not be read/listed)               -> DIVERGENT
       16  fatal error                                       -> DIVERGENT
       <0  process terminated/abnormal                       -> DIVERGENT

    The output lines are parsed only to REPORT pending files/bytes. If the exit
    code says divergent but no line could be parsed, MismatchCount is still >= 1
    (fail closed): the verdict never depends on the parser recognising anything.

    Optional sampled SHA256 hashing adds content-level assurance.

.PARAMETER RobocopyRunner
    Injectable list-pass runner. Signature:
        { param($Source,$Dest) -> [pscustomobject]@{ ExitCode=<int>; Lines=<string[]> } }

.OUTPUTS
    PSCustomObject: Method, MismatchCount, ExitCode, PendingFiles, PendingBytes,
    ListErrors, HashSamplesChecked, HashMismatches.

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
            # Native stderr must not become a terminating error under 'Stop'.
            $ErrorActionPreference = 'Continue'
            # Keep the exclusion flags (/XJ ...) identical to the copy pass.
            $out  = & $robo $Source $Dest /L /E /BYTES /NJH /NJS /NC /NDL /FP /NP /XJ /R:0 /W:0 2>&1
            $code = $LASTEXITCODE
            [pscustomobject]@{
                ExitCode = $code
                Lines    = @($out | ForEach-Object { [string]$_ })
            }
        }
    }

    $run = & $RobocopyRunner $SourcePath $DestinationPath
    if ($null -eq $run -or -not $run.PSObject.Properties['ExitCode'] -or
        -not $run.PSObject.Properties['Lines']) {
        throw [System.InvalidOperationException]::new(
            'RobocopyRunner must return an object with ExitCode and Lines.')
    }

    $exit = [int]$run.ExitCode

    # Bits 1 (copy), 4 (mismatch), 8 (failure), 16 (fatal) => divergent. Bit 2 is benign.
    $divergent = ($exit -lt 0) -or (($exit -band (1 -bor 4 -bor 8 -bor 16)) -ne 0)

    $pendingFiles = 0
    $pendingBytes = [long]0
    $listErrors   = 0
    foreach ($line in @($run.Lines)) {
        $entry = ConvertFrom-RobocopyLine -Line ([string]$line)
        if (-not $entry) { continue }
        switch ($entry.Type) {
            'File'  { $pendingFiles++; $pendingBytes += $entry.Size }
            'Error' { $listErrors++ }
        }
    }

    # Fail closed: the exit code alone is enough to reject.
    $mismatchCount = [Math]::Max($pendingFiles + $listErrors, [int]$divergent)

    # --- Optional sampled hashing (unchanged behaviour) -----------------------
    $samplesChecked = 0
    $hashMismatches = 0
    $method         = 'RobocopyExitCode'

    if ($SampleHashCount -gt 0 -and (Test-Path -LiteralPath $SourcePath)) {
        $method = 'RobocopyExitCode+SampledSHA256'

        $sourceBase = (Resolve-Path -LiteralPath $SourcePath).ProviderPath.TrimEnd('\')
        $baseLength = $sourceBase.Length

        $allFiles = @(Get-ChildItem -LiteralPath $sourceBase -Recurse -File -ErrorAction SilentlyContinue)
        if ($allFiles.Count -gt 0) {
            $take        = [Math]::Min($SampleHashCount, $allFiles.Count)
            $sourceFiles = $allFiles | Get-Random -Count $take

            foreach ($sf in @($sourceFiles)) {
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
        ExitCode           = $exit
        PendingFiles       = $pendingFiles
        PendingBytes       = $pendingBytes
        ListErrors         = $listErrors
        HashSamplesChecked = $samplesChecked
        HashMismatches     = $hashMismatches
    }
}
