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
            $script:CapturedArgs | Should -Match '/UNILOG:'
            $script:CapturedArgs | Should -Not -Match '/LOG:'
            $script:CapturedArgs | Should -Match '/FP'
            $script:CapturedArgs | Should -Match '/XJ'
            $script:CapturedArgs | Should -Not -Match '/TS'
        }
    }

    It 'quotes a drive root as X:\. so it is not read as drive-relative' {
        InModuleScope EscapeFromCorporate -Parameters @{ TestLog = $script:TestLog } {
            param($TestLog)

            $script:CapturedArgs = $null
            $fakeFactory = {
                param($FilePath, $Arguments, $LogPath)
                $script:CapturedArgs = $Arguments
                [pscustomobject]@{ Process = [pscustomobject]@{ Id = 1 }; ProcessId = 1 }
            }

            Connect-Robocopy -SourcePath 'C:\' -DestinationPath 'D:\' `
                -LogPath $TestLog -ProcessFactory $fakeFactory | Out-Null

            $script:CapturedArgs | Should -Match '"C:\\\."'
            $script:CapturedArgs | Should -Match '"D:\\\."'
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


Describe 'Read-RobocopyLog (incremental delta reader, UTF-16 /UNILOG)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    BeforeEach {
        $script:Log = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.log')
        # UTF-16LE with BOM: exactly what robocopy /UNILOG produces.
        $script:U16 = [System.Text.UnicodeEncoding]::new($false, $true)
    }

    It 'reads only new bytes across successive polls' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; U16 = $script:U16 } {
            param($Log, $U16)

            [System.IO.File]::WriteAllText($Log,
                "       1024        C:\data\a.txt`r`n       2048        C:\data\b.txt`r`n", $U16)

            $pass1 = Read-RobocopyLog -LogPath $Log -ByteOffset 0
            @($pass1.Entries).Count | Should -Be 2
            $pass1.NewByteOffset    | Should -BeGreaterThan 0

            [System.IO.File]::AppendAllText($Log, "       4096        C:\data\c.txt`r`n", $U16)

            $pass2 = Read-RobocopyLog -LogPath $Log -ByteOffset $pass1.NewByteOffset

            # Only the newly appended line is parsed this pass.
            @($pass2.Entries).Count     | Should -Be 1
            @($pass2.Entries)[0].Size   | Should -Be 4096
        }
    }

    It 'leaves an incomplete trailing line unconsumed and returns it whole once finished' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; U16 = $script:U16 } {
            param($Log, $U16)

            # A complete line plus a half-written one (no line terminator yet).
            [System.IO.File]::WriteAllText($Log,
                "       512        C:\data\complete.txt`r`n       999        C:\data\incomp", $U16)

            $r1 = Read-RobocopyLog -LogPath $Log -ByteOffset 0
            @($r1.Entries).Count | Should -Be 1

            # robocopy finishes the line.
            [System.IO.File]::AppendAllText($Log, "lete.txt`r`n", $U16)

            $r2 = Read-RobocopyLog -LogPath $Log -ByteOffset $r1.NewByteOffset

            # Exactly one entry, with the EXACT path (no duplicated fragment).
            @($r2.Entries).Count        | Should -Be 1
            @($r2.Entries)[0].Path      | Should -BeExactly 'C:\data\incomplete.txt'
            @($r2.Entries)[0].Size      | Should -Be 999
        }
    }

    It 'never moves the offset backwards while a partial line sits idle' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; U16 = $script:U16 } {
            param($Log, $U16)

            [System.IO.File]::WriteAllText($Log,
                "       512        C:\data\a.txt`r`n       99", $U16)

            $offset = [long]0
            $seen   = @()
            1..5 | ForEach-Object {
                $r = Read-RobocopyLog -LogPath $Log -ByteOffset $offset
                $offset = $r.NewByteOffset
                $seen  += $offset
            }
            @($seen | Select-Object -Unique).Count | Should -Be 1
        }
    }

    It 'returns unchanged state when the log has not grown' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; U16 = $script:U16 } {
            param($Log, $U16)

            [System.IO.File]::WriteAllText($Log, "       100        C:\x.txt`r`n", $U16)

            $first  = Read-RobocopyLog -LogPath $Log -ByteOffset 0
            $second = Read-RobocopyLog -LogPath $Log -ByteOffset $first.NewByteOffset

            @($second.Entries).Count | Should -Be 0
            $second.NewByteOffset    | Should -Be $first.NewByteOffset
        }
    }

    It 'is byte-accurate and preserves accented paths (UTF-16)' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; U16 = $script:U16 } {
            param($Log, $U16)

            $name = 'arquivo-' + [char]0x00E7 + [char]0x00E3 + 'o-' + [char]0x00FC + [char]0x00F1 + '.txt'
            $line = "       256        C:\dados\$name`r`n"
            [System.IO.File]::WriteAllText($Log, $line, $U16)

            $r = Read-RobocopyLog -LogPath $Log -ByteOffset 0

            # Offset must equal the true byte length (BOM + UTF-16 payload), not the character count.
            $r.NewByteOffset         | Should -Be ($U16.GetPreamble().Length + $U16.GetByteCount($line))
            @($r.Entries)[0].Path    | Should -BeExactly "C:\dados\$name"
        }
    }

    It 'restarts from the beginning when the log is smaller than the offset (truncated or rotated)' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; U16 = $script:U16 } {
            param($Log, $U16)

            [System.IO.File]::WriteAllText($Log, "       7        C:\x\new.txt`r`n", $U16)

            $r = Read-RobocopyLog -LogPath $Log -ByteOffset 999999
            @($r.Entries).Count | Should -Be 1
        }
    }

    It 'does not lock the file (robocopy can keep writing)' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log; U16 = $script:U16 } {
            param($Log, $U16)

            [System.IO.File]::WriteAllText($Log, "       10        C:\y.txt`r`n", $U16)

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
