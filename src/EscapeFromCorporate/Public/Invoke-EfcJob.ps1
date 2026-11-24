#Requires -Version 5.1
<#
.SYNOPSIS
    Securely copies a directory tree to a destination (local or UNC) with resumable,
    validated, progress-tracked transfers powered by robocopy.

.DESCRIPTION
    Invoke-EfcJob is the primary controller for Escape From Corporate. It orchestrates
    the full lifecycle of a secure file dump:

      1. Pre-flight validation (existence, root reachability, source/destination
         self-collision) and enumeration of pending work via 'robocopy /L' -
         always performed, so percentComplete/ETA are accurate for every run,
         not only -DryRun requests.
      2. Idempotent resumption reconciliation against any persisted state.json.
      3. Background robocopy spawn with file-based logging (no pipe deadlock).
      4. A non-blocking watch loop rendering a live spinner, ETA, percentage, and
         throughput, while capturing P/R/A keystrokes for Pause/Resume/Abort.
      5. Atomic checkpoint persistence to allow interrupted jobs to resume exactly.
      6. Post-copy integrity validation and a clear "safe to delete" signal.

    Source/Destination use rsync-style trailing-slash semantics: a trailing
    separator on -Source ('C:\Data\') copies the CONTENTS of Source into
    Destination; no trailing separator ('C:\Data') copies Source ITSELF as a
    subfolder of Destination. This matches `rsync SRC DEST` exactly.

    BREAKING CHANGE (v2.0.0): versions prior to 2.0.0 always used
    contents-only semantics regardless of trailing slash. Any existing script
    or scheduled task calling efc without a trailing separator on -Source will
    now land files one directory level deeper than before. Run with -DryRun
    first to confirm the resolved destination before relying on a prior
    automation unattended.

    Because this cmdlet can move or overwrite large amounts of data, it
    carries ConfirmImpact 'High': by default it prompts for confirmation
    before starting a real transfer. Pass -Confirm:$false for unattended or
    scripted use.

    The utility is designed for locked-down corporate Windows 11 environments with no
    administrator privileges and no third-party sync tools; it relies solely on native
    PowerShell 5.1 and robocopy.exe.

.PARAMETER Source
    Path to the source directory to copy from. Positional (rsync-style): the
    -Source flag name itself is optional. A trailing separator ('\' or '/')
    copies Source's CONTENTS into Destination; no trailing separator nests
    Source ITSELF as a subfolder of Destination.

.PARAMETER Destination
    Destination directory. Supports local paths and UNC shares (\\server\share\...).
    Positional (rsync-style): the -Destination flag name itself is optional.

.PARAMETER Force
    Discards any existing job state for this source/destination pair and starts a
    clean transfer. Without -Force, a matching incomplete job is resumed.

.PARAMETER DryRun
    Reports the projected file count, total bytes, and (when Source has no
    trailing separator) the rsync-resolved effective destination, without
    copying anything.

.PARAMETER AllowSameDrive
    Allows a destination on the same drive (or network share) as the source. By
    default efc refuses it, because a copy within one drive does not protect
    against losing that drive. Aliases (subst, mapped drives, junctions, symlinks)
    are resolved before comparing. Copying a folder into itself stays refused.

.PARAMETER Restartable
    Enables robocopy restartable mode (/Z) for resilient resumption of large files
    over unreliable network links. Slightly slower but far more robust.

.PARAMETER SampleHashCount
    Number of files to sample for SHA256 content verification during the post-copy
    integrity check. 0 (default) uses robocopy differential list validation only.
    Higher values add content-level assurance at the cost of hashing that many
    random files at both the source and destination.

.PARAMETER StateRoot
    Overrides the state directory. Defaults to $env:LOCALAPPDATA\EscapeFromCorporate.
    Primarily an injection seam for testing.

.PARAMETER Help
    Displays full help for this command and exits without touching any files
    or requiring -Source/-Destination.

.PARAMETER Version
    Displays the installed module version and exits without touching any
    files or requiring -Source/-Destination.

.EXAMPLE
    efc C:\Data\ \\NAS\Dump

    rsync-style, positional: the trailing slash on Source copies its CONTENTS
    directly into \\NAS\Dump (robocopy's native behavior).

.EXAMPLE
    efc C:\Data \\NAS\Dump

    rsync-style, positional: no trailing slash nests Source itself as a
    subfolder, so files land under \\NAS\Dump\Data.

.EXAMPLE
    Invoke-EfcJob -Source 'C:\Data' -Destination 'D:\Backup' -DryRun

    Projects how many files and bytes would be copied, and shows the
    effective (rsync-resolved) destination, without transferring anything.

.EXAMPLE
    Invoke-EfcJob -Source 'C:\Data' -Destination '\\NAS\Dump' -Force

    Ignores any prior state and starts a completely fresh transfer.

.EXAMPLE
    efc -Source 'C:\Data' -Destination '\\NAS\Dump' -Restartable

    Uses the 'efc' alias with restartable mode for large files over a flaky link.

.EXAMPLE
    Invoke-EfcJob -Source 'C:\Legal\Case\' -Destination '\\NAS\Vault' -SampleHashCount 200

    After copying, verifies 200 randomly selected files by SHA256 at both source and
    destination. Any content mismatch fails validation and blocks the safe-to-delete
    signal.

.EXAMPLE
    efc -Help

    Displays full command help and exits.

.EXAMPLE
    efc -Version

    Displays the installed module version and exits.

.INPUTS
    None. Parameters are supplied explicitly.

.OUTPUTS
    PSCustomObject summarizing the final job state (status, metrics, validation,
    safeToDeleteSource) for a normal or resumed run; a projection summary for
    -DryRun; nothing (help text streamed to the console) for -Help; a small
    Name/Version object for -Version.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0

    At runtime: press P to pause, R to resume, A to abort.

.LINK
    https://github.com/yorgabr/EscapeFromCorporate
#>
function Invoke-EfcJob {
    <#
    .EXTERNALHELP EscapeFromCorporate-help.xml
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Run')]
    [Alias('efc', 'Escape-FromCorporate', 'Invoke-Efc')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName = 'Run', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(ParameterSetName = 'Run', Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,

        [switch] $Force,

        [switch] $DryRun,

        [switch] $Restartable,

        [switch] $AllowSameDrive,

        # Number of files to sample for SHA256 content verification during the
        # post-copy integrity check. 0 (default) uses robocopy differential list
        # validation only. Higher values add content-level assurance at the cost
        # of hashing that many random files at both source and destination.
        [ValidateRange(0, 10000)]
        [int] $SampleHashCount = 0,

        [string] $StateRoot = (Join-Path $env:LOCALAPPDATA 'EscapeFromCorporate'),

        [Parameter(ParameterSetName = 'Help', Mandatory)]
        [Alias('h')]
        [switch] $Help,

        [Parameter(ParameterSetName = 'Version', Mandatory)]
        [Alias('v')]
        [switch] $Version
    )

    begin {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Help') {
            Get-Help -Name 'Invoke-EfcJob' -Full
            return
        }

        if ($PSCmdlet.ParameterSetName -eq 'Version') {
            $moduleInfo    = $MyInvocation.MyCommand.Module
            $versionString = if ($moduleInfo) { $moduleInfo.Version.ToString() } else { 'unknown' }
            Write-Host "Escape From Corporate (efc) v$versionString"
            return [pscustomobject]@{ Name = 'EscapeFromCorporate'; Version = $versionString }
        }

        # --- rsync-style destination resolution ---------------------------------
        $effectiveDestination = Resolve-EfcEffectiveDestination -Source $Source -Destination $Destination
        if ($effectiveDestination -ne $Destination) {
            Write-Verbose "No trailing separator on Source; rsync-style nesting applies. Effective destination: $effectiveDestination"
        }

        # --- Resolve log path under the state root -----------------------------
        $logDir  = Join-Path $StateRoot 'logs'
        $logPath = Join-Path $logDir ('{0}.log' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))

        # --- 1. Pre-flight -------------------------------------------------------
        # Enumeration always runs, independent of -DryRun: see the note on
        # Test-EfcPreflight's -Enumerate parameter for why this matters.
        Write-Verbose 'Running pre-flight checks.'
        $preflight = Test-EfcPreflight -SourcePath $Source -DestinationPath $effectiveDestination -Enumerate -AllowSameDrive:$AllowSameDrive

        if (-not $preflight.IsValid) {
            foreach ($m in $preflight.Messages) { Write-Error $m }
            throw 'Pre-flight validation failed. See errors above.'
        }

        if ($DryRun) {
            Write-Host ''
            Write-Host 'DryRun projection (no data copied):' -ForegroundColor Cyan
            Write-Host ("  Source                 : {0}" -f $Source)
            Write-Host ("  Destination (as typed) : {0}" -f $Destination)
            if ($effectiveDestination -ne $Destination) {
                Write-Host ("  Destination (effective): {0}" -f $effectiveDestination) -ForegroundColor Yellow
                Write-Host "  (rsync-style: Source has no trailing separator, so it nests as a subfolder)" -ForegroundColor DarkYellow
            }
            Write-Host ("  Files : {0:N0}" -f $preflight.TotalFiles)
            Write-Host ("  Bytes : {0:N0} ({1})" -f $preflight.TotalBytes,
                        (Format-EfcBytes -Bytes $preflight.TotalBytes))
            Write-Host ("  Dirs  : {0:N0}" -f $preflight.TotalDirs)
            return [pscustomobject]@{
                Status                = 'DryRun'
                TotalFiles            = $preflight.TotalFiles
                TotalBytes            = $preflight.TotalBytes
                TotalDirs             = $preflight.TotalDirs
                EffectiveDestination  = $effectiveDestination
            }
        }

        # --- 2. Resumption reconciliation --------------------------------------
        # Uses the RAW Destination (as typed), not the effective one: this keeps
        # job identity (combinedKey) and Resume-EfcJob replay stable and
        # idempotent - the effective destination is re-derived fresh on every
        # run from (Source, raw Destination), rather than persisting an
        # already-nested path that would double-nest on the next resume.
        $existing = Get-EfcState -StateRoot $StateRoot
        $decision = Resolve-EfcResumption -ExistingState $existing `
            -SourcePath $Source -DestinationPath $Destination -Force:$Force

        Write-Verbose "Resumption decision: $($decision.Decision) - $($decision.Reason)"

        switch ($decision.Decision) {
            'Conflict' {
                throw $decision.Reason
            }
            'AlreadyCompleted' {
                Write-Host $decision.Reason -ForegroundColor Green
                return $existing
            }
        }

        # --- 3. Build / rehydrate state ----------------------------------------
        $isResuming = $decision.Decision -eq 'Resume'

        if ($isResuming) {
            $state = $existing
            $state.status = 'Running'
            $state.control.resumeCount++
            $state.logPointer.logByteOffset     = $decision.ResumeByteOffset
            $state.logPointer.partialLineBuffer = $decision.ResumePartialBuffer
            Write-Host "Resuming interrupted job (offset $($decision.ResumeByteOffset))." -ForegroundColor Yellow
        }
        else {
            $state = New-EfcState -SourcePath $Source -DestinationPath $Destination -LogPath $logPath
            $state.status = 'Running'
            $state.metrics.totalFilesExpected = $preflight.TotalFiles
            $state.metrics.totalBytesExpected = $preflight.TotalBytes
            $logPath = $state.robocopy.logPath  # honor state's log path on fresh start

            if ($decision.Decision -eq 'DifferentialRestart') {
                Write-Host 'Note: resuming via robocopy differential. Progress may jump as identical files are skipped.' -ForegroundColor Yellow
            }
        }

        $shouldProcessTarget = if ($effectiveDestination -ne $Destination) {
            "$effectiveDestination (nested under $Destination)"
        }
        else {
            $Destination
        }
        if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, "Copy from $Source")) {
            return
        }

        # --- 4. Spawn robocopy in background -----------------------------------
        $descriptor = Connect-Robocopy `
            -SourcePath $Source `
            -DestinationPath $effectiveDestination `
            -LogPath $state.robocopy.logPath `
            -Restartable:$Restartable

        $state.robocopy.processId   = $descriptor.ProcessId
        $state.robocopy.commandLine = $descriptor.CommandLine
        $state.robocopy.flags       = $descriptor.Flags
        $state.robocopy.startedUtc  = $descriptor.StartedUtc
        $state.history += [pscustomobject]@{
            event = 'ProcessStarted'; timestampUtc = $descriptor.StartedUtc
            detail = "Robocopy PID $($descriptor.ProcessId)"
        }
        Write-EfcState -State $state -StateRoot $StateRoot

        # --- 5. Watch loop (UI + control + checkpoint) -------------------------
        $final = Watch-RobocopyProcess `
            -Process $descriptor.Process `
            -State $state `
            -StateRoot $StateRoot

        # --- 6. Post-copy validation -------------------------------------------
        $exitCode = $final.robocopy.exitCode
        if ($final.status -eq 'Aborted') {
            # A killed process reports a negative/odd exit code: never let it overwrite
            # the Aborted status or trigger a validation of a partial copy.
            Write-Verbose 'Transfer aborted or interrupted; skipping validation.'
            $final.validation.safeToDeleteSource = $false
        }
        elseif ($null -ne $exitCode -and $exitCode -ge 0 -and $exitCode -lt 8) {
            Write-Verbose "Robocopy exit code indicates success; validating integrity."
            if ($SampleHashCount -gt 0) {
                Write-Verbose "Integrity check will sample $SampleHashCount file(s) for SHA256 verification."
            }

            $validation = Test-EfcCopyIntegrity `
                -SourcePath $Source `
                -DestinationPath $effectiveDestination `
                -SampleHashCount $SampleHashCount

            $final.validation.performed         = $true
            $final.validation.method            = $validation.Method
            $final.validation.mismatchCount     = $validation.MismatchCount
            $final.validation.validatedUtc      = [datetime]::UtcNow.ToString('o')
            $final.validation.safeToDeleteSource = ($validation.MismatchCount -eq 0)
            $final.status = if ($validation.MismatchCount -eq 0) { 'Completed' } else { 'ValidationFailed' }

            # Record traceability of how validation was performed.
            $final.validation | Add-Member -NotePropertyName 'sampleHashCount' `
                -NotePropertyValue $SampleHashCount -Force
            $final.validation | Add-Member -NotePropertyName 'hashSamplesChecked' `
                -NotePropertyValue $validation.HashSamplesChecked -Force
            $final.validation | Add-Member -NotePropertyName 'hashMismatches' `
                -NotePropertyValue $validation.HashMismatches -Force
        }
        else {
            $final.status = 'Failed'
        }

        Write-EfcState -State $final -StateRoot $StateRoot

        # --- 7. Final user notification ----------------------------------------
        Write-EfcSummary -State $final

        return $final
    }
}

