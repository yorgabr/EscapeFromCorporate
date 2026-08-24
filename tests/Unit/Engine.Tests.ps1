#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Connect-Robocopy' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
        $script:TestLog = Join-Path $TestDrive 'synthetic.log'
    }

    It 'builds the optimized flag set without /NS and with /BYTES' {
        InModuleScope EscapeFromCorporate -Parameters @{ TestLog = $script:TestLog } {
            param($TestLog)

            $script:CapturedArgs = $null

            # Fake factory: captures arguments, simulates a started process, no real spawn.
            $fakeFactory = {
                param($FilePath, $Arguments, $LogPath)
                $script:CapturedArgs = $Arguments
                [pscustomobject]@{
                    Process   = [pscustomobject]@{ Id = 4242; HasExited = $false }
                    ProcessId = 4242
                }
            }

            $desc = Connect-Robocopy `
                -SourcePath 'C:\src' `
                -DestinationPath '\\NAS\dst' `
                -LogPath $TestLog `
                -ProcessFactory $fakeFactory

            $desc.ProcessId | Should -Be 4242
            $script:CapturedArgs | Should -Match '/BYTES'
            $script:CapturedArgs | Should -Match '/E'
            $script:CapturedArgs | Should -Not -Match '/NS\b'
            $script:CapturedArgs | Should -Match '/LOG:'
        }
    }

    It 'adds /Z only when -Restartable is supplied' {
        InModuleScope EscapeFromCorporate -Parameters @{ TestLog = $script:TestLog } {
            param($TestLog)

            $script:CapturedArgs = $null
            $fakeFactory = {
                param($FilePath, $Arguments, $LogPath)
                $script:CapturedArgs = $Arguments
                [pscustomobject]@{ Process = [pscustomobject]@{ Id = 1 }; ProcessId = 1 }
            }

            Connect-Robocopy -SourcePath 'C:\a' -DestinationPath 'C:\b' `
                -LogPath $TestLog -Restartable -ProcessFactory $fakeFactory | Out-Null

            $script:CapturedArgs | Should -Match '/Z\b'
        }
    }

    It 'throws when the factory returns no valid PID' {
        InModuleScope EscapeFromCorporate -Parameters @{ TestLog = $script:TestLog } {
            param($TestLog)

            $badFactory = { param($f,$a,$l) [pscustomobject]@{ Process = $null; ProcessId = $null } }

            { Connect-Robocopy -SourcePath 'C:\a' -DestinationPath 'C:\b' `
                -LogPath $TestLog -ProcessFactory $badFactory } |
                Should -Throw '*valid started process*'
        }
    }
}


Describe 'Read-RobocopyLog (incremental delta reader)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    BeforeEach {
        $script:Log = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.log')
        $script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    }

    It 'reads only new bytes across successive polls' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; Utf8NoBom = $script:Utf8NoBom } {
            param($Log, $Utf8NoBom)

            # First write: two complete lines.
            $chunk1 = "New File `t1024`tC:\data\a.txt`n" +
                      "New File `t2048`tC:\data\b.txt`n"
            [System.IO.File]::WriteAllText($Log, $chunk1, $Utf8NoBom)

            $pass1 = Read-RobocopyLog -LogPath $Log -ByteOffset 0
            $pass1.Entries.Count       | Should -Be 2
            $pass1.PartialLineBuffer   | Should -BeNullOrEmpty
            $pass1.NewByteOffset       | Should -BeGreaterThan 0

            # Second write: append one more complete line.
            $chunk2 = "New File `t4096`tC:\data\c.txt`n"
            [System.IO.File]::AppendAllText($Log, $chunk2, $Utf8NoBom)

            $pass2 = Read-RobocopyLog -LogPath $Log `
                -ByteOffset $pass1.NewByteOffset `
                -PartialLineBuffer $pass1.PartialLineBuffer

            # Only the newly appended line should be parsed this pass.
            $pass2.Entries.Count | Should -Be 1
            $pass2.Entries[0].Size | Should -Be 4096
        }
    }

    It 'holds an incomplete trailing line in PartialLineBuffer' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; Utf8NoBom = $script:Utf8NoBom } {
            param($Log, $Utf8NoBom)

            # Write a complete line + a half-written line (no trailing newline).
            $partial = "New File `t512`tC:\data\complete.txt`n" +
                       "New File `t999`tC:\data\incomp"
            [System.IO.File]::WriteAllText($Log, $partial, $Utf8NoBom)

            $r1 = Read-RobocopyLog -LogPath $Log -ByteOffset 0
            $r1.Entries.Count       | Should -Be 1
            $r1.PartialLineBuffer   | Should -Match 'incomp'

            # Complete the previously partial line.
            [System.IO.File]::AppendAllText($Log, "lete.txt`n", $Utf8NoBom)

            $r2 = Read-RobocopyLog -LogPath $Log `
                -ByteOffset $r1.NewByteOffset `
                -PartialLineBuffer $r1.PartialLineBuffer

            $r2.Entries.Count      | Should -Be 1
            $r2.Entries[0].Path    | Should -Match 'incomplete\.txt$'
        }
    }

    It 'returns unchanged state when the log has not grown' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; Utf8NoBom = $script:Utf8NoBom } {
            param($Log, $Utf8NoBom)

            $line = "New File `t100`tC:\x.txt`n"
            [System.IO.File]::WriteAllText($Log, $line, $Utf8NoBom)

            $first  = Read-RobocopyLog -LogPath $Log -ByteOffset 0
            $second = Read-RobocopyLog -LogPath $Log -ByteOffset $first.NewByteOffset

            $second.Entries.Count | Should -Be 0
            $second.NewByteOffset | Should -Be $first.NewByteOffset
        }
    }

    It 'is byte-accurate with multibyte UTF8 paths' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; Utf8NoBom = $script:Utf8NoBom } {
            param($Log, $Utf8NoBom)

            $line = "New File `t256`tC:\dados\arquivo-ção-üñ.txt`n"
            [System.IO.File]::WriteAllText($Log, $line, $Utf8NoBom)

            $r = Read-RobocopyLog -LogPath $Log -ByteOffset 0

            # Offset must equal the true byte length, not the character count.
            $expectedBytes = $Utf8NoBom.GetByteCount($line)
            $r.NewByteOffset | Should -Be $expectedBytes
        }
    }

    It 'does not lock the file (robocopy can keep writing)' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; Utf8NoBom = $script:Utf8NoBom } {
            param($Log, $Utf8NoBom)

            $line = "New File `t10`tC:\y.txt`n"
            [System.IO.File]::WriteAllText($Log, $line, $Utf8NoBom)

            # While our reader runs, a concurrent write handle must succeed.
            Read-RobocopyLog -LogPath $Log -ByteOffset 0 | Out-Null

            {
                $fs = [System.IO.FileStream]::new(
                    $Log,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite)
                $fs.Dispose()
            } | Should -Not -Throw
        }
    }
}