#Requires -Version 5.1
<#
.SYNOPSIS
    Spawns robocopy.exe as a detached background process with file-based logging.

.DESCRIPTION
    Constructs an optimized robocopy argument set for silent, byte-precise logging
    and launches it via [System.Diagnostics.Process]. Deliberately avoids STDOUT
    pipe redirection to prevent buffer deadlocks during multi-gigabyte transfers;
    robocopy writes directly to its own log file (/LOG) which is consumed
    asynchronously by Read-RobocopyLog.

    Returns a descriptor object carrying the live Process handle, PID, resolved
    log path, and the exact command line for state persistence.

.PARAMETER SourcePath
    Absolute source directory to copy from.

.PARAMETER DestinationPath
    Destination directory (local or UNC).

.PARAMETER LogPath
    Full path to the robocopy log file to be written and later polled.

.PARAMETER Restartable
    When set, adds /Z (restartable mode) for resilient resumption of large files.

.PARAMETER RetryCount
    Robocopy /R value. Defaults to 2 to avoid long stalls on locked files.

.PARAMETER RetryWaitSeconds
    Robocopy /W value. Defaults to 5 seconds.

.PARAMETER ProcessFactory
    Injectable script block that produces a started process from a file path and
    argument string. Enables mocking in tests without executing real robocopy.
    Signature: { param($FilePath, $Arguments, $LogPath) -> [pscustomobject] }

.OUTPUTS
    PSCustomObject with: Process, ProcessId, LogPath, CommandLine, Flags, StartedUtc.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Connect-Robocopy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DestinationPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LogPath,

        [switch] $Restartable,

        [ValidateRange(0, 100)]
        [int] $RetryCount = 2,

        [ValidateRange(0, 3600)]
        [int] $RetryWaitSeconds = 5,

        [scriptblock] $ProcessFactory
    )

    Set-StrictMode -Version Latest

    # --- Ensure the log directory exists (robocopy will not create it) ----------
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # --- Build the optimized flag set (see Phase 1 architectural decision #1) ---
    #   /E      : copy subdirectories including empty ones
    #   /BYTES  : sizes in bytes (deterministic parsing, no unit conversion)
    #   /NJH    : no job header
    #   /NJS    : no job summary
    #   /NC     : no file class column (leaner lines)
    #   /NS     : no size column in the per-file listing... 
    #             NOTE: with /BYTES we DO want sizes, so /NS is intentionally omitted here.
    #   /TS     : include timestamps per entry (progress correlation)
    #   /NP     : no per-file percentage spam (we compute our own progress)
    #   /R:n /W:n : bounded retries
    $flags = [System.Collections.Generic.List[string]]::new()
    $flags.Add('/E')
    $flags.Add('/BYTES')
    $flags.Add('/NJH')
    $flags.Add('/NJS')
    $flags.Add('/NC')
    $flags.Add('/TS')
    $flags.Add('/NP')
    $flags.Add("/R:$RetryCount")
    $flags.Add("/W:$RetryWaitSeconds")
    if ($Restartable) { $flags.Add('/Z') }

    # Log routing: /LOG overwrites, /TEE would echo to console (undesired here).
    $flags.Add("/LOG:$LogPath")

    # --- Assemble the argument string with quoted paths -------------------------
    $quotedSource = '"{0}"' -f $SourcePath.TrimEnd('\')
    $quotedDest   = '"{0}"' -f $DestinationPath.TrimEnd('\')
    $argumentLine = '{0} {1} {2}' -f $quotedSource, $quotedDest, ($flags -join ' ')

    $robocopyExe = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $commandLine = '{0} {1}' -f $robocopyExe, $argumentLine

    Write-Verbose "Robocopy command: $commandLine"

    # --- Launch via injectable factory (real or mocked) -------------------------
    if (-not $ProcessFactory) {
        $ProcessFactory = {
            param($FilePath, $Arguments, $LogPath)

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $FilePath
            $psi.Arguments              = $Arguments
            $psi.UseShellExecute        = $false   # required for no-window spawn
            $psi.CreateNoWindow         = $true
            $psi.RedirectStandardOutput = $false   # log goes to file, not pipe
            $psi.RedirectStandardError  = $false
            $psi.WorkingDirectory       = (Split-Path -Parent $FilePath)

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            [void] $proc.Start()

            return [pscustomobject]@{
                Process   = $proc
                ProcessId = $proc.Id
            }
        }
    }

    $spawn = & $ProcessFactory $robocopyExe $argumentLine $LogPath

    if (-not $spawn -or -not $spawn.ProcessId) {
        throw "Process factory failed to return a valid started process descriptor."
    }

    # --- Return the descriptor consumed by the watch loop + state layer ---------
    return [pscustomobject]@{
        Process     = $spawn.Process
        ProcessId   = $spawn.ProcessId
        LogPath     = $LogPath
        CommandLine = $commandLine
        Flags       = $flags.ToArray()
        StartedUtc  = [datetime]::UtcNow.ToString('o')
    }
}
