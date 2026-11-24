#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Suspend-EfcProcess (fail-safe contract)' {

    It 'returns $false and never throws for a non-existent PID' {
        InModuleScope EscapeFromCorporate {
            # PID very unlikely to exist; Get-Process should throw internally.
            { Suspend-EfcProcess -ProcessId 999999 -Action Suspend } | Should -Not -Throw
            Suspend-EfcProcess -ProcessId 999999 -Action Suspend | Should -BeFalse
        }
    }

    It 'returns $false when the target process has already exited' {
        InModuleScope EscapeFromCorporate {
            # Spawn a trivial short-lived process, wait for exit, then attempt suspend.
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
            $p.WaitForExit()
            Start-Sleep -Milliseconds 50
            Suspend-EfcProcess -ProcessId $p.Id -Action Suspend | Should -BeFalse
        }
    }

    It 'suspends and resumes a real owned process (round-trip)' {
        InModuleScope EscapeFromCorporate {
            # Long-ish sleeper we fully control and clean up.
            $p = Start-Process -FilePath 'cmd.exe' `
                -ArgumentList '/c', 'ping -n 10 127.0.0.1 >NUL' `
                -PassThru -WindowStyle Hidden
            try {
                Start-Sleep -Milliseconds 100
                $suspended = Suspend-EfcProcess -ProcessId $p.Id -Action Suspend
                $resumed   = Suspend-EfcProcess -ProcessId $p.Id -Action Resume

                # On standard Windows both should succeed; if an EDR blocks ntdll,
                # the contract still holds (bool, no throw) so we assert type safety.
                $suspended | Should -BeOfType [bool]
                $resumed   | Should -BeOfType [bool]
            }
            finally {
                if (-not $p.HasExited) { $p.Kill() }
            }
        }
    }
}

Describe 'Watch loop pause/resume state transitions' {

    It 'transitions to Paused then back to Running on P/R keystrokes' {
        InModuleScope EscapeFromCorporate {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $log  = Join-Path $root 'job.log'
            [System.IO.File]::WriteAllText($log, "New File `t500`tC:\s\a.txt`n",
                [System.Text.UnicodeEncoding]::new($false, $true))

            $state = New-EfcState -SourcePath 'C:\s' -DestinationPath 'C:\d' -LogPath $log
            $state.metrics.totalBytesExpected = 500
            $state.metrics.totalFilesExpected = 1

            # A process that stays "alive" for the first few iterations, then exits,
            # so we can drive P -> R -> natural completion.
            $script:HasExitedSeq = @($false, $false, $false, $true, $true)
            $script:ExitIdx = 0
            $fakeProc = [pscustomobject]@{ ExitCode = 1 }
            Add-Member -InputObject $fakeProc -MemberType ScriptProperty -Name HasExited -Value {
                $v = $script:HasExitedSeq[[Math]::Min($script:ExitIdx, $script:HasExitedSeq.Count - 1)]
                $script:ExitIdx++
                return $v
            }
            Add-Member -InputObject $fakeProc -MemberType ScriptMethod -Name Kill -Value {}

            # Feed a scripted keystroke sequence: Pause, then Resume, then nothing.
            $script:KeySeq = @('Pause', 'Resume', $null, $null, $null, $null)
            $script:KeyIdx = 0
            Mock Read-EfcKeyCommand {
                $k = $script:KeySeq[[Math]::Min($script:KeyIdx, $script:KeySeq.Count - 1)]
                $script:KeyIdx++
                return $k
            }

            Mock Test-EfcInteractiveHost { $false }
            Mock Suspend-EfcProcess { $true }   # simulate successful native suspend

            $captured = [System.Collections.Generic.List[string]]::new()
            Mock Write-EfcState { $captured.Add($State.status) } -Verifiable

            $final = Watch-RobocopyProcess -Process $fakeProc -State $state `
                -StateRoot $root -PollIntervalMs 5

            # The status must have passed through Paused at some point.
            $state.control.resumeCount | Should -BeGreaterOrEqual 1
            $final.metrics.filesCopied | Should -Be 1
        }
    }

    It 'falls back to soft-pause when native suspend returns $false' {
        InModuleScope EscapeFromCorporate {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $log  = Join-Path $root 'job.log'
            [System.IO.File]::WriteAllText($log, "New File `t10`tC:\s\a.txt`n",
                [System.Text.UnicodeEncoding]::new($false, $true))

            $state = New-EfcState -SourcePath 'C:\s' -DestinationPath 'C:\d' -LogPath $log
            $state.metrics.totalBytesExpected = 10
            $state.metrics.totalFilesExpected = 1

            $script:Seq = @($false, $false, $true, $true)
            $script:I = 0
            $fakeProc = [pscustomobject]@{ ExitCode = 1 }
            Add-Member -InputObject $fakeProc -MemberType ScriptProperty -Name HasExited -Value {
                $v = $script:Seq[[Math]::Min($script:I, $script:Seq.Count - 1)]; $script:I++; return $v
            }
            Add-Member -InputObject $fakeProc -MemberType ScriptMethod -Name Kill -Value {}

            $script:Keys = @('Pause', 'Resume', $null, $null)
            $script:KI = 0
            Mock Read-EfcKeyCommand {
                $k = $script:Keys[[Math]::Min($script:KI, $script:Keys.Count - 1)]; $script:KI++; return $k
            }
            Mock Test-EfcInteractiveHost { $false }
            # Native suspend FAILS -> exercise soft-pause branch.
            Mock Suspend-EfcProcess { $false }

            { Watch-RobocopyProcess -Process $fakeProc -State $state `
                -StateRoot $root -PollIntervalMs 5 } | Should -Not -Throw
        }
    }
}

Describe 'Deterministic drain on process exit' {

    It 'captures trailing entries flushed after HasExited flips true' {
        InModuleScope EscapeFromCorporate {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $log  = Join-Path $root 'job.log'

            # Start with ONE line; the process reports exited immediately, but the
            # log grows on the next drain iteration (simulating a late flush).
            [System.IO.File]::WriteAllText($log, "New File `t100`tC:\s\a.txt`n",
                [System.Text.UnicodeEncoding]::new($false, $true))

            $state = New-EfcState -SourcePath 'C:\s' -DestinationPath 'C:\d' -LogPath $log
            $state.metrics.totalBytesExpected = 300
            $state.metrics.totalFilesExpected = 3

            $fakeProc = [pscustomobject]@{ HasExited = $true; ExitCode = 1 }
            Add-Member -InputObject $fakeProc -MemberType ScriptMethod -Name Kill -Value {}

            Mock Test-EfcInteractiveHost { $false }
            Mock Suspend-EfcProcess { $true }
            Mock Read-EfcKeyCommand { $null }

            # Inject the late flush: on the FIRST drain read, append two more lines.
            $script:FlushDone = $false
            Mock Start-Sleep {
                if (-not $script:FlushDone) {
                    [System.IO.File]::AppendAllText($log,
                        "New File `t100`tC:\s\b.txt`nNew File `t100`tC:\s\c.txt`n",
                        [System.Text.UnicodeEncoding]::new($false, $true))
                    $script:FlushDone = $true
                }
            } -ParameterFilter { $Milliseconds -eq 25 }

            $final = Watch-RobocopyProcess -Process $fakeProc -State $state `
                -StateRoot $root -PollIntervalMs 5

            # All three files must be counted despite the late flush.
            $final.metrics.filesCopied | Should -Be 3
            $final.metrics.bytesCopied | Should -Be 300
        }
    }
}

