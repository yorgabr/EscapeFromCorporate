#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'End-to-end job orchestration (fully mocked SO/process)' {

    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:Src  = Join-Path $script:Root 'src'
        $script:Dst  = Join-Path $script:Root 'dst'
        New-Item -ItemType Directory -Path $script:Src -Force | Out-Null
        New-Item -ItemType Directory -Path $script:Dst -Force | Out-Null
        1..3 | ForEach-Object {
            Set-Content -Path (Join-Path $script:Src "file$_.txt") -Value ("data" * $_)
        }
    }

    It 'DryRun projects totals without copying' {
        InModuleScope EscapeFromCorporate -Parameters @{ Src = $script:Src; Dst = $script:Dst; Root = $script:Root } {
            param($Src, $Dst, $Root)

            Mock Test-EfcPreflight {
                [pscustomobject]@{
                    IsValid = $true; Messages = @(); TotalFiles = 3; TotalBytes = 120; TotalDirs = 1
                }
            }

            $result = Invoke-EfcJob -Source $Src -Destination $Dst -DryRun -StateRoot $Root
            $result.Status     | Should -Be 'DryRun'
            $result.TotalFiles | Should -Be 3
        }
    }

    It 'runs a full mocked transfer and reaches Completed with safe-to-delete' {
        InModuleScope EscapeFromCorporate -Parameters @{ Src = $script:Src; Dst = $script:Dst; Root = $script:Root } {
            param($Src, $Dst, $Root)

            # Preflight passes with known totals.
            Mock Test-EfcPreflight {
                [pscustomobject]@{
                    IsValid = $true; Messages = @(); TotalFiles = 2; TotalBytes = 3000; TotalDirs = 0
                }
            }

            # Connect-Robocopy: fake a process and materialize a complete log.
            Mock Connect-Robocopy {
                $logPath = $LogPath
                $content = "New File `t1000`tC:\s\a.txt`n" +
                           "New File `t2000`tC:\s\b.txt`n"
                $dir = Split-Path -Parent $logPath
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [System.IO.File]::WriteAllText($logPath, $content, [System.Text.UTF8Encoding]::new($false))

                $proc = [pscustomobject]@{ HasExited = $true; ExitCode = 1 }
                Add-Member -InputObject $proc -MemberType ScriptMethod -Name Kill -Value {}

                [pscustomobject]@{
                    Process     = $proc
                    ProcessId   = 9999
                    LogPath     = $logPath
                    CommandLine = 'robocopy (mocked)'
                    Flags       = @('/E','/BYTES')
                    StartedUtc  = [datetime]::UtcNow.ToString('o')
                }
            }

            # Non-interactive host so the spinner degrades to linear (no cursor ops).
            Mock Test-EfcInteractiveHost { $false }
            Mock Suspend-EfcProcess { $true }

            # Integrity: zero mismatches -> safe to delete.
            Mock Test-EfcCopyIntegrity {
                [pscustomobject]@{
                    Method = 'RobocopyDifferentialList'; MismatchCount = 0
                    HashSamplesChecked = 0; HashMismatches = 0
                }
            }

            $final = Invoke-EfcJob -Source $Src -Destination $Dst -StateRoot $Root -Confirm:$false

            $final.status                         | Should -Be 'Completed'
            $final.validation.safeToDeleteSource  | Should -BeTrue
            $final.metrics.filesCopied            | Should -Be 2
            $final.metrics.bytesCopied            | Should -Be 3000
        }
    }

    It 'always requests preflight enumeration, even for a real (non-DryRun) transfer' {
        InModuleScope EscapeFromCorporate -Parameters @{ Src = $script:Src; Dst = $script:Dst; Root = $script:Root } {
            param($Src, $Dst, $Root)

            # Regression guard for a real bug: Test-EfcPreflight's enumeration
            # used to be gated on the caller's -DryRun switch, so a REAL
            # transfer never learned its total file/byte counts, silently
            # breaking percentComplete/ETA for the life of the job. This test
            # asserts Invoke-EfcJob always requests -Enumerate, regardless of
            # whether the user asked for -DryRun.
            $script:CapturedEnumerate = $false
            Mock Test-EfcPreflight {
                $script:CapturedEnumerate = [bool]$Enumerate
                [pscustomobject]@{
                    IsValid = $true; Messages = @(); TotalFiles = 2; TotalBytes = 3000; TotalDirs = 0
                }
            }
            Mock Connect-Robocopy {
                $dir = Split-Path -Parent $LogPath
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [System.IO.File]::WriteAllText($LogPath, "New File `t1000`tC:\s\a.txt`n",
                    [System.Text.UTF8Encoding]::new($false))
                $proc = [pscustomobject]@{ HasExited = $true; ExitCode = 1 }
                Add-Member -InputObject $proc -MemberType ScriptMethod -Name Kill -Value {}
                [pscustomobject]@{
                    Process = $proc; ProcessId = 1; LogPath = $LogPath
                    CommandLine = 'x'; Flags = @(); StartedUtc = [datetime]::UtcNow.ToString('o')
                }
            }
            Mock Test-EfcInteractiveHost { $false }
            Mock Suspend-EfcProcess { $true }
            Mock Test-EfcCopyIntegrity {
                [pscustomobject]@{ Method = 'x'; MismatchCount = 0; HashSamplesChecked = 0; HashMismatches = 0 }
            }

            $final = Invoke-EfcJob -Source $Src -Destination $Dst -StateRoot $Root -Confirm:$false

            $script:CapturedEnumerate          | Should -BeTrue
            $final.metrics.totalFilesExpected  | Should -Be 2
            $final.metrics.totalBytesExpected  | Should -Be 3000
        }
    }

    It 'marks ValidationFailed when integrity reports mismatches' {
        InModuleScope EscapeFromCorporate -Parameters @{ Src = $script:Src; Dst = $script:Dst; Root = $script:Root } {
            param($Src, $Dst, $Root)

            Mock Test-EfcPreflight {
                [pscustomobject]@{ IsValid = $true; Messages = @(); TotalFiles = 1; TotalBytes = 1000; TotalDirs = 0 }
            }
            Mock Connect-Robocopy {
                $dir = Split-Path -Parent $LogPath
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [System.IO.File]::WriteAllText($LogPath, "New File `t1000`tC:\s\a.txt`n",
                    [System.Text.UTF8Encoding]::new($false))
                $proc = [pscustomobject]@{ HasExited = $true; ExitCode = 1 }
                Add-Member -InputObject $proc -MemberType ScriptMethod -Name Kill -Value {}
                [pscustomobject]@{
                    Process = $proc; ProcessId = 1; LogPath = $LogPath
                    CommandLine = 'x'; Flags = @(); StartedUtc = [datetime]::UtcNow.ToString('o')
                }
            }
            Mock Test-EfcInteractiveHost { $false }
            Mock Suspend-EfcProcess { $true }
            Mock Test-EfcCopyIntegrity {
                [pscustomobject]@{ Method = 'x'; MismatchCount = 5; HashSamplesChecked = 0; HashMismatches = 0 }
            }

            $final = Invoke-EfcJob -Source $Src -Destination $Dst -StateRoot $Root -Confirm:$false
            $final.status                        | Should -Be 'ValidationFailed'
            $final.validation.safeToDeleteSource | Should -BeFalse
        }
    }

    It 'throws Conflict when a different job occupies the state slot' {
        InModuleScope EscapeFromCorporate -Parameters @{ Src = $script:Src; Dst = $script:Dst; Root = $script:Root } {
            param($Src, $Dst, $Root)

            $prior = New-EfcState -SourcePath 'C:\totally\different' -DestinationPath 'C:\other' `
                -LogPath (Join-Path $Root 'logs\x.log')
            Write-EfcState -State $prior -StateRoot $Root

            Mock Test-EfcPreflight {
                [pscustomobject]@{ IsValid = $true; Messages = @(); TotalFiles = 0; TotalBytes = 0; TotalDirs = 0 }
            }

            { Invoke-EfcJob -Source $Src -Destination $Dst -StateRoot $Root -Confirm:$false } |
                Should -Throw '*different source/destination*'
        }
    }

    It 'passes SampleHashCount through to the integrity check' {
        InModuleScope EscapeFromCorporate -Parameters @{ Src = $script:Src; Dst = $script:Dst; Root = $script:Root } {
            param($Src, $Dst, $Root)

            Mock Test-EfcPreflight {
                [pscustomobject]@{ IsValid = $true; Messages = @(); TotalFiles = 1; TotalBytes = 1000; TotalDirs = 0 }
            }
            Mock Connect-Robocopy {
                $dir = Split-Path -Parent $LogPath
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [System.IO.File]::WriteAllText($LogPath, "New File `t1000`tC:\s\a.txt`n",
                    [System.Text.UTF8Encoding]::new($false))
                $proc = [pscustomobject]@{ HasExited = $true; ExitCode = 1 }
                Add-Member -InputObject $proc -MemberType ScriptMethod -Name Kill -Value {}
                [pscustomobject]@{
                    Process = $proc; ProcessId = 1; LogPath = $LogPath
                    CommandLine = 'x'; Flags = @(); StartedUtc = [datetime]::UtcNow.ToString('o')
                }
            }
            Mock Test-EfcInteractiveHost { $false }
            Mock Suspend-EfcProcess { $true }

            # Capture the value SampleHashCount was invoked with.
            $script:CapturedSample = -1
            Mock Test-EfcCopyIntegrity {
                $script:CapturedSample = $SampleHashCount
                [pscustomobject]@{
                    Method = 'RobocopyList+SampledSHA256'; MismatchCount = 0
                    HashSamplesChecked = $SampleHashCount; HashMismatches = 0
                }
            }

            $final = Invoke-EfcJob -Source $Src -Destination $Dst -StateRoot $Root `
                -SampleHashCount 50 -Confirm:$false

            $script:CapturedSample                     | Should -Be 50
            $final.validation.sampleHashCount          | Should -Be 50
            $final.validation.hashSamplesChecked       | Should -Be 50
            $final.validation.safeToDeleteSource       | Should -BeTrue
            $final.validation.method                   | Should -Be 'RobocopyList+SampledSHA256'
        }
    }

    It 'blocks safe-to-delete when a sampled hash mismatch is found' {
        InModuleScope EscapeFromCorporate -Parameters @{ Src = $script:Src; Dst = $script:Dst; Root = $script:Root } {
            param($Src, $Dst, $Root)

            Mock Test-EfcPreflight {
                [pscustomobject]@{ IsValid = $true; Messages = @(); TotalFiles = 1; TotalBytes = 1000; TotalDirs = 0 }
            }
            Mock Connect-Robocopy {
                $dir = Split-Path -Parent $LogPath
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [System.IO.File]::WriteAllText($LogPath, "New File `t1000`tC:\s\a.txt`n",
                    [System.Text.UTF8Encoding]::new($false))
                $proc = [pscustomobject]@{ HasExited = $true; ExitCode = 1 }
                Add-Member -InputObject $proc -MemberType ScriptMethod -Name Kill -Value {}
                [pscustomobject]@{
                    Process = $proc; ProcessId = 1; LogPath = $LogPath
                    CommandLine = 'x'; Flags = @(); StartedUtc = [datetime]::UtcNow.ToString('o')
                }
            }
            Mock Test-EfcInteractiveHost { $false }
            Mock Suspend-EfcProcess { $true }
            Mock Test-EfcCopyIntegrity {
                [pscustomobject]@{
                    Method = 'RobocopyList+SampledSHA256'; MismatchCount = 2
                    HashSamplesChecked = 10; HashMismatches = 2
                }
            }

            $final = Invoke-EfcJob -Source $Src -Destination $Dst -StateRoot $Root `
                -SampleHashCount 10 -Confirm:$false

            $final.status                        | Should -Be 'ValidationFailed'
            $final.validation.safeToDeleteSource | Should -BeFalse
            $final.validation.hashMismatches     | Should -Be 2
        }
    }

    It 'defaults SampleHashCount to 0 (list-only validation) when omitted' {
        InModuleScope EscapeFromCorporate -Parameters @{ Src = $script:Src; Dst = $script:Dst; Root = $script:Root } {
            param($Src, $Dst, $Root)

            Mock Test-EfcPreflight {
                [pscustomobject]@{ IsValid = $true; Messages = @(); TotalFiles = 1; TotalBytes = 1000; TotalDirs = 0 }
            }
            Mock Connect-Robocopy {
                $dir = Split-Path -Parent $LogPath
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [System.IO.File]::WriteAllText($LogPath, "New File `t1000`tC:\s\a.txt`n",
                    [System.Text.UTF8Encoding]::new($false))
                $proc = [pscustomobject]@{ HasExited = $true; ExitCode = 1 }
                Add-Member -InputObject $proc -MemberType ScriptMethod -Name Kill -Value {}
                [pscustomobject]@{
                    Process = $proc; ProcessId = 1; LogPath = $LogPath
                    CommandLine = 'x'; Flags = @(); StartedUtc = [datetime]::UtcNow.ToString('o')
                }
            }
            Mock Test-EfcInteractiveHost { $false }
            Mock Suspend-EfcProcess { $true }

            $script:CapturedSample = -1
            Mock Test-EfcCopyIntegrity {
                $script:CapturedSample = $SampleHashCount
                [pscustomobject]@{
                    Method = 'RobocopyDifferentialList'; MismatchCount = 0
                    HashSamplesChecked = 0; HashMismatches = 0
                }
            }

            $final = Invoke-EfcJob -Source $Src -Destination $Dst -StateRoot $Root -Confirm:$false

            $script:CapturedSample            | Should -Be 0
            $final.validation.method          | Should -Be 'RobocopyDifferentialList'
        }
    }
}

Describe 'Invoke-EfcJob -Help / -Version' {

    It '-Help displays help without requiring Source/Destination' {
        { Invoke-EfcJob -Help } | Should -Not -Throw
    }

    It '-Version returns the installed module version without requiring Source/Destination' {
        $result = Invoke-EfcJob -Version
        $result.Name    | Should -Be 'EscapeFromCorporate'
        $result.Version | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-EfcCopyIntegrity (differential validation)' {
    BeforeAll { Import-Module $script:ModulePath -Force }

    It 'reports zero mismatches when the list pass is empty' {
        InModuleScope EscapeFromCorporate {
            $runner = { param($s,$d) @('', '   ', '------ banner ------') }
            $r = Test-EfcCopyIntegrity -SourcePath 'C:\s' -DestinationPath 'C:\d' -RobocopyRunner $runner
            $r.MismatchCount | Should -Be 0
        }
    }

    It 'counts each still-pending file as a mismatch' {
        InModuleScope EscapeFromCorporate {
            $runner = {
                param($s,$d)
                @("New File `t100`tC:\s\pending1.txt", "New File `t200`tC:\s\pending2.txt")
            }
            $r = Test-EfcCopyIntegrity -SourcePath 'C:\s' -DestinationPath 'C:\d' -RobocopyRunner $runner
            $r.MismatchCount | Should -Be 2
        }
    }
}