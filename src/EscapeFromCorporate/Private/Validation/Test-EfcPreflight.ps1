#Requires -Version 5.1
<#
.SYNOPSIS
    Validates job feasibility and computes baseline file/byte counts.

.DESCRIPTION
    Runs a series of guards - source existence, destination root
    reachability, source/destination self-collision, and source/destination on
    the same drive or share - and, when
    -Enumerate is set, executes 'robocopy /L /E /BYTES /NJH /NJS /NC /FP /NP /XJ' to
    enumerate the pending work WITHOUT copying. The parsed totals seed the
    progress state so the UI can render an accurate ETA from the very first
    frame.

    -Enumerate is requested for EVERY job by Invoke-EfcJob, not only for
    -DryRun requests: without it, a real transfer would never learn its total
    file/byte counts, and percentComplete/ETA would never populate for the
    life of the job. -DryRun (a separate, caller-side concept) only controls
    whether Invoke-EfcJob reports the projection and stops, or proceeds to
    copy after reporting it.

.PARAMETER SourcePath
    Absolute source directory.

.PARAMETER DestinationPath
    The EFFECTIVE destination directory (local or UNC) - i.e. after
    rsync-style trailing-slash resolution has already been applied by the
    caller, not necessarily the raw -Destination argument the user typed.

.PARAMETER Enumerate
    When set, performs the list-only enumeration and returns the projected totals.

.PARAMETER AllowSameDrive
    By default a destination on the same drive (or network share) as the source is
    refused: that is not an off-box copy and protects nothing against losing the
    drive. Subst drives, mapped drives, junctions and symlinks are resolved first,
    so aliases cannot hide it. The override does NOT disable the self-copy guard:
    a destination that turns out to be the source (or inside it) after resolving
    aliases is still refused.

.PARAMETER PathResolver
    Injectable resolver for guard 4: { param($Path) -> resolved path }. Defaults to
    Resolve-EfcFinalPath. Enables tests without real aliases.

.PARAMETER RobocopyRunner
    Injectable script block that executes a robocopy list pass and returns its
    stdout lines. Enables mocking. Signature: { param($Source,$Dest) -> string[] }

.OUTPUTS
    PSCustomObject: IsValid, Messages, TotalFiles, TotalBytes, TotalDirs.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Test-EfcPreflight {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [switch] $Enumerate,
        [switch] $AllowSameDrive,
        [scriptblock] $PathResolver,
        [scriptblock] $RobocopyRunner
    )

    Set-StrictMode -Version Latest

    $messages = [System.Collections.Generic.List[string]]::new()
    $isValid  = $true

    # --- Guard 0: reject blank/whitespace-only paths ---------------------------
    if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($DestinationPath)) {
        $isValid = $false
        $messages.Add("Source and Destination must not be blank or whitespace-only.")
    }

    # --- Guard 1: source must exist and be a directory -------------------------
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        $isValid = $false
        $messages.Add("Source path does not exist or is not a directory: $SourcePath")
    }

    # --- Guard 2: destination root reachability (local drive or UNC share) -----
    # Only the true root needs to exist - robocopy creates arbitrarily deep
    # subdirectories beneath it on its own. Checking just the immediate parent
    # (the old behavior) was both too strict for legitimate brand-new
    # multi-level destinations, and too lax for local drives: an unmounted or
    # disconnected local drive letter was never caught before, only UNC
    # shares were checked at all.
    $destRoot = Get-EfcPathRoot -Path $DestinationPath
    if ($destRoot -and -not (Test-Path -LiteralPath $destRoot)) {
        $isValid = $false
        if ($DestinationPath -like '\\*') {
            $messages.Add("Destination UNC share is unreachable: $destRoot")
        }
        else {
            $messages.Add("Destination drive is not available: $destRoot")
        }
    }

    # --- Guard 3: source/destination self-collision -----------------------------
    # If the destination robocopy will actually write to is the same directory
    # as the source, or lies INSIDE the source tree, robocopy would attempt to
    # copy the source into itself (unbounded growth or a self-referential
    # mirror). DestinationPath here is expected to already be the EFFECTIVE
    # destination (post rsync-nesting resolution), since collisions are often
    # only introduced by that resolution - e.g. `efc C:\Data\Sub C:\Data`
    # resolves, without this guard, to an effective destination identical to
    # the source.
    $sourceSig = Get-EfcSignature -Path $SourcePath
    $destSig   = Get-EfcSignature -Path $DestinationPath
    $collision = $false

    if ($sourceSig.NormalizedPath -eq $destSig.NormalizedPath) {
        $isValid = $false
        $collision = $true
        $messages.Add("Source and destination resolve to the same path ('$($sourceSig.NormalizedPath)'). Refusing to proceed.")
    }
    elseif ($destSig.NormalizedPath.StartsWith("$($sourceSig.NormalizedPath)\", [System.StringComparison]::OrdinalIgnoreCase)) {
        $isValid = $false
        $collision = $true
        $messages.Add("Destination is nested inside source ('$($destSig.NormalizedPath)' is under '$($sourceSig.NormalizedPath)'). This would copy the source into itself. Refusing to proceed.")
    }

    # --- Guard 4: source and destination on the same drive / share -------------
    # A copy inside one drive is not an off-box copy. Both paths are resolved
    # through subst drives, mapped drives, junctions and symlinks first. Only an
    # EXPLICIT match is refused; paths whose drive cannot be determined fall
    # through to the other guards.
    if (-not [string]::IsNullOrWhiteSpace($SourcePath) -and
        -not [string]::IsNullOrWhiteSpace($DestinationPath)) {

        $driveArgs = @{ SourcePath = $SourcePath; DestinationPath = $DestinationPath }
        if ($PathResolver) { $driveArgs['PathResolver'] = $PathResolver }
        $drive = Test-EfcSameDrive @driveArgs

        if ($drive.Same) {
            $aliasNote = ''
            if ($drive.SourceAliased) {
                $aliasNote += " Source '$SourcePath' resolves to '$($drive.SourceFinal)'."
            }
            if ($drive.DestinationAliased) {
                $aliasNote += " Destination '$DestinationPath' resolves to '$($drive.DestinationFinal)'."
            }

            if (-not $AllowSameDrive) {
                $isValid = $false
                $messages.Add("Source and destination are on the same drive ('$($drive.SourceKey)').$aliasNote Copying within one drive does not protect against losing it. Use another drive or a network share, or pass -AllowSameDrive to override.")
            }

            # The override never disables the self-copy protection: aliases can hide
            # a destination that is the source (or inside it) from guard 3.
            if (-not $collision) {
                $resolvedSource = $drive.SourceFinal.TrimEnd('\')
                $resolvedDest   = $drive.DestinationFinal.TrimEnd('\')

                if ($resolvedSource -eq $resolvedDest) {
                    $isValid = $false
                    $messages.Add("Source and destination resolve to the same folder ('$resolvedSource') once aliases are resolved.$aliasNote Refusing to proceed.")
                }
                elseif ($resolvedDest.StartsWith("$resolvedSource\", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isValid = $false
                    $messages.Add("Destination is nested inside source once aliases are resolved ('$resolvedDest' is under '$resolvedSource').$aliasNote This would copy the source into itself. Refusing to proceed.")
                }
            }
        }
    }

    $totalFiles = [long]0
    $totalBytes = [long]0
    $totalDirs  = [long]0

    if ($Enumerate -and $isValid) {
        Write-Verbose "Enumerating pending work via robocopy /L."

        if (-not $RobocopyRunner) {
            $RobocopyRunner = {
                param($Source, $Dest)
                $robo = Join-Path $env:SystemRoot 'System32\robocopy.exe'
                # /L = list only (no copy). Same lean flags as the real transfer.
                & $robo $Source $Dest /L /E /BYTES /NJH /NJS /NC /FP /NP /XJ /R:0 /W:0 2>&1
            }
        }

        $lines = & $RobocopyRunner $SourcePath $DestinationPath

        foreach ($line in $lines) {
            $entry = ConvertFrom-RobocopyLine -Line ([string]$line)
            if (-not $entry) { continue }

            switch ($entry.Type) {
                'File' {
                    $totalFiles++
                    $totalBytes += $entry.Size
                }
                'Dir' {
                    $totalDirs++
                }
            }
        }

        $messages.Add("Projection: $totalFiles file(s), $totalBytes byte(s), $totalDirs dir(s).")
    }

    return [pscustomobject]@{
        IsValid    = $isValid
        Messages   = $messages.ToArray()
        TotalFiles = $totalFiles
        TotalBytes = $totalBytes
        TotalDirs  = $totalDirs
    }
}

