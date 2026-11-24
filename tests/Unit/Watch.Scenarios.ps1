#Requires -Version 5.1
<#
.SYNOPSIS
    Scenario checks for Watch-RobocopyProcess (abort, pause, Ctrl+C, resume baseline).

.DESCRIPTION
    Every scenario runs in its own background job with a hard timeout, so a loop
    that never exits (the old Pause -> Abort defect) is reported as a failure
    instead of hanging the build. OS-bound pieces (UI, ntdll suspend, state IO,
    process kill) are replaced by recording stubs; the log reader, the parser and
    the metrics reducer are the REAL implementations.

    Exit code: 0 when every scenario passes, 1 otherwise. Wire it into
    Invoke-Build as a Test step. Not a Pester file on purpose (no *.Tests.ps1).
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [int]    $TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$scenarioBody = {
    param([string] $Root, [string] $Scenario)
    $ErrorActionPreference = 'Stop'

    # Real implementations: every private file, then stubs on top.
    Get-ChildItem -LiteralPath (Join-Path $Root 'src\EscapeFromCorporate\Private') -Recurse -Filter '*.ps1' |
        Sort-Object FullName | ForEach-Object { . $_.FullName }

    $script:frames = 0
    $script:calls  = New-Object System.Collections.Generic.List[string]
    $script:saved  = $null
    $keys = switch ($Scenario) {
        'abort'        { @{ 1 = 'Abort' } }
        'pause-abort'  { @{ 1 = 'Pause'; 3 = 'Abort' } }
        'pause-resume' { @{ 1 = 'Pause'; 3 = 'Resume' } }
        default        { @{} }
    }
    $script:keymap = $keys
    $exitAfter = if ($Scenario -in 'normal', 'pause-resume', 'resumed') { 8 } else { 1000000 }
    $proc = [pscustomobject]@{ HasExited = $false; ExitCode = $null }
    $script:proc = $proc

    function Write-EfcSpinner {
        param($State, [switch] $PausedIndicator)
        $script:frames++
        if ($script:frames -ge $exitAfter -and -not $script:proc.HasExited) {
            $script:proc.HasExited = $true; $script:proc.ExitCode = 1
        }
        if ($Scenario -eq 'error' -and $script:frames -ge 3) { throw 'simulated terminating error / Ctrl+C' }
    }
    function Read-EfcKeyCommand { if ($script:keymap.ContainsKey($script:frames)) { $script:keymap[$script:frames] } else { $null } }
    function Suspend-EfcProcess { param($ProcessId, $Action) $script:calls.Add("Suspend:$Action"); $true }
    function Stop-RobocopyProcess { param($Process) $script:calls.Add('Stop'); $Process.HasExited = $true; $Process.ExitCode = -1 }
    function Write-EfcState {
        param($State, $StateRoot)
        $script:saved = [pscustomobject]@{ Status = $State.status; Events = @($State.history | ForEach-Object { $_.event }) }
    }

    $tmp = [System.IO.Path]::GetTempFileName()
    $u16 = New-Object System.Text.UnicodeEncoding($false, $true)
    $text = "       100        C:\a\1.bin`r`n       200        C:\a\2.bin`r`n       300        C:\a\3.bin`r`n"
    [System.IO.File]::WriteAllBytes($tmp, $u16.GetPreamble() + $u16.GetBytes($text))

    $state = New-EfcState -SourcePath 'C:\a' -DestinationPath 'C:\b' -LogPath $tmp
    if ($Scenario -eq 'resumed') { $state.metrics.bytesCopied = 1000; $state.metrics.elapsedSeconds = 50 }

    $thrown = $null
    try { [void](Watch-RobocopyProcess -Process $proc -State $state -StateRoot ([System.IO.Path]::GetTempPath()) -PollIntervalMs 10 6>$null) }
    catch { $thrown = $_.Exception.Message }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue

    [pscustomobject]@{
        Status = $state.status; ExitCode = $state.robocopy.exitCode
        Files = $state.metrics.filesCopied; Bytes = $state.metrics.bytesCopied
        Elapsed = $state.metrics.elapsedSeconds; Resumes = $state.control.resumeCount
        Calls = ($script:calls -join ','); Thrown = $thrown
        SavedStatus = $(if ($script:saved) { $script:saved.Status } else { $null })
        SavedEvents = $(if ($script:saved) { $script:saved.Events -join ',' } else { '' })
    }
}

$expect = [ordered]@{
    'normal'       = { $_.Files -eq 3 -and $_.Bytes -eq 600 -and $_.ExitCode -eq 1 -and $_.Calls -eq '' -and -not $_.Thrown }
    'abort'        = { $_.Status -eq 'Aborted' -and $_.Calls -eq 'Stop' }
    'pause-abort'  = { $_.Status -eq 'Aborted' -and $_.Calls -eq 'Suspend:Suspend,Suspend:Resume,Stop' }
    'pause-resume' = { $_.Resumes -eq 1 -and $_.ExitCode -eq 1 -and $_.Files -eq 3 -and $_.Calls -eq 'Suspend:Suspend,Suspend:Resume' }
    'error'        = { $_.Thrown -and $_.Calls -eq 'Stop' -and $_.SavedStatus -eq 'Aborted' -and $_.SavedEvents -match 'Interrupted' }
    'resumed'      = { $_.Bytes -eq 1600 -and $_.Elapsed -ge 50 }
}

$failed = 0
foreach ($name in $expect.Keys) {
    $job = Start-Job -ScriptBlock $scenarioBody -ArgumentList $Root, $name
    if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
        Stop-Job -Job $job; Remove-Job -Job $job -Force
        '{0,-14} FAIL  (timeout: the watch loop never exited)' -f $name; $failed++; continue
    }
    $r = Receive-Job -Job $job -ErrorAction SilentlyContinue | Select-Object -Last 1
    Remove-Job -Job $job -Force
    $ok = $false
    if ($r) { $ok = [bool]($r | Where-Object $expect[$name]) }
    '{0,-14} {1}  status={2} files={3} bytes={4} calls=[{5}]' -f $name, $(if ($ok) { 'ok  ' } else { 'FAIL' }),
        $(if ($r) { $r.Status } else { '?' }), $(if ($r) { $r.Files } else { '?' }),
        $(if ($r) { $r.Bytes } else { '?' }), $(if ($r) { $r.Calls } else { '?' })
    if (-not $ok) { $failed++ }
}
if ($failed) { "$failed scenario(s) failed."; exit 1 } else { 'All watch scenarios passed.'; exit 0 }
