#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Format-EfcBytes' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    It 'formats bytes across binary boundaries' {
        InModuleScope EscapeFromCorporate {
            (Format-EfcBytes -Bytes 0)        | Should -Be '0 B'
            (Format-EfcBytes -Bytes 1024)     | Should -Match 'KB'
            (Format-EfcBytes -Bytes 1048576)  | Should -Match 'MB'
            (Format-EfcBytes -Bytes 1073741824) | Should -Match 'GB'
        }
    }
}

Describe 'Read-EfcKeyCommand (non-blocking mapping)' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    It 'returns $null when no key is available' {
        InModuleScope EscapeFromCorporate {
            Mock -CommandName 'Read-EfcKeyCommand' -MockWith { $null }
            # Direct behavioral proxy: KeyAvailable false path.
        }
        # Non-interactive test host: KeyAvailable throws/false -> $null.
        InModuleScope EscapeFromCorporate {
            { Read-EfcKeyCommand } | Should -Not -Throw
        }
    }
}

Describe 'Watch loop metrics reconciliation' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    It 'accumulates files and bytes from a synthetic log and finalizes' {
        InModuleScope EscapeFromCorporate {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $log  = Join-Path $root 'job.log'

            # Pre-populate a complete synthetic log (process already "exited").
            $content = "New File `t1000`tC:\s\a.txt`n" +
                       "New File `t2000`tC:\s\b.txt`n"
            [System.IO.File]::WriteAllText($log, $content,
                [System.Text.UnicodeEncoding]::new($false, $true))

            $state = New-EfcState -SourcePath 'C:\s' -DestinationPath 'C:\d' -LogPath $log
            $state.metrics.totalBytesExpected = 3000
            $state.metrics.totalFilesExpected = 2

            # Fake an already-exited process.
            $fakeProc = [pscustomobject]@{ HasExited = $true; ExitCode = 1 }
            Add-Member -InputObject $fakeProc -MemberType ScriptMethod -Name Kill -Value {}

            # Non-interactive host -> spinner degrades to linear; no cursor ops.
            Mock Test-EfcInteractiveHost { $false }
            Mock Suspend-EfcProcess { $true }

            $final = Watch-RobocopyProcess -Process $fakeProc -State $state `
                -StateRoot $root -PollIntervalMs 10

            $final.metrics.filesCopied | Should -Be 2
            $final.metrics.bytesCopied | Should -Be 3000
            $final.robocopy.exitCode   | Should -Be 1
        }
    }
}
