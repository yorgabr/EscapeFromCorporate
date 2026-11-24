#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Regression tests built from REAL robocopy output captured on pt-BR Windows
# PowerShell 5.1 (2026-11-12). ASCII-only on purpose: accents are built with
# [char] so the file is safe regardless of BOM/encoding.

BeforeDiscovery {
    $o = [char]0x00F3; $c = [char]0x00E7; $a = [char]0x00E3

    $script:LineCases = @(
        @{ Name = 'file line (/NC /FP)';          Line = '                               8        C:\Temp\efc-t\a\um.txt';                 Type = 'File'; Size = 8 }
        @{ Name = 'root directory header';        Line = '               1        C:\Temp\efc-t\a\';                                       Type = 'Dir';  Size = 0 }
        @{ Name = 'directory header with space';  Line = '               1        C:\Temp\efc-t\a\sub dir\';                               Type = 'Dir';  Size = 0 }
        @{ Name = 'pt-BR label: Novo Arquivo';    Line = '          Novo Arquivo                 8        C:\Temp\efc-t\a\um.txt';          Type = 'File'; Size = 8 }
        @{ Name = 'pt-BR label: Novo Dir';        Line = '            Novo Dir       1    C:\Temp\efc-t\a\sub dir\';                       Type = 'Dir';  Size = 0 }
        @{ Name = 'accented path';                Line = "          Novo Arquivo              2005        C:\Temp\efc-t\a\sub dir\relat${o}rio-${c}${a}o.txt"; Type = 'File'; Size = 2005 }
        @{ Name = 'UNC file';                     Line = '       1234        \\NAS\share\dir\f.txt';                                       Type = 'File'; Size = 1234 }
        @{ Name = 'legacy en-US label';           Line = "New File `t1000`tC:\s\a.txt";                                                    Type = 'File'; Size = 1000 }
        @{ Name = 'pt-BR error with timestamp';   Line = '2026/11/08 17:41:24 ERRO 267 (0x0000010B) Acessando o Diretorio de Origem C:\temp\a\'; Type = 'Error'; Size = 0 }
        @{ Name = 'en-US error without timestamp'; Line = 'ERROR 5 (0x00000005) Copying File C:\x\y.txt';                                      Type = 'Error'; Size = 0 }
    )

    $script:Unrecognised = @(
        @{ Name = '/TS without /FP (no directory context)'; Line = '                           8 2026/11/12 23:32:31    um.txt' }
        @{ Name = 'separator';                              Line = '-------------------------------' }
    )
}

Describe 'robocopy real output' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    Context 'ConvertFrom-RobocopyLine' {

        It 'classifies <Name>' -ForEach $script:LineCases {
            InModuleScope EscapeFromCorporate -Parameters @{ Line = $Line; Type = $Type; Size = $Size } {
                param($Line, $Type, $Size)
                $e = ConvertFrom-RobocopyLine -Line $Line
                $e | Should -Not -BeNullOrEmpty
                $e.Type | Should -Be $Type
                $e.Size | Should -Be $Size
            }
        }

        It 'returns the full path of a file line exactly' {
            InModuleScope EscapeFromCorporate {
                $e = ConvertFrom-RobocopyLine -Line '                               8        C:\Temp\efc-t\a\um.txt'
                $e.Path | Should -BeExactly 'C:\Temp\efc-t\a\um.txt'
            }
        }

        It 'extracts the numeric code of a localized error' {
            InModuleScope EscapeFromCorporate {
                (ConvertFrom-RobocopyLine -Line '2026/11/08 17:41:24 ERRO 267 (0x0000010B) x').Code | Should -Be 267
            }
        }

        It 'does not recognise <Name>' -ForEach $script:Unrecognised {
            InModuleScope EscapeFromCorporate -Parameters @{ Line = $Line } {
                param($Line)
                ConvertFrom-RobocopyLine -Line $Line | Should -BeNullOrEmpty
            }
        }

        It 'never counts a directory header as a file (the original defect)' {
            InModuleScope EscapeFromCorporate {
                $headers = @('               1        C:\Temp\efc-t\a\', '               1        C:\Temp\efc-t\a\sub dir\')
                @($headers | ForEach-Object { ConvertFrom-RobocopyLine -Line $_ } | Where-Object Type -eq 'File').Count | Should -Be 0
            }
        }
    }

    Context 'Test-EfcCopyIntegrity: verdict comes from the exit code' {

        It 'accepts a synced tree even when robocopy prints directory headers (exit 0)' {
            InModuleScope EscapeFromCorporate {
                $runner = { param($s, $d) [pscustomobject]@{ ExitCode = 0; Lines = @('               1        C:\a\', '               1        C:\a\sub dir\') } }
                (Test-EfcCopyIntegrity -SourcePath 'C:\a' -DestinationPath 'C:\b' -RobocopyRunner $runner).MismatchCount | Should -Be 0
            }
        }

        It 'reports a pending file (exit 1) with its size' {
            InModuleScope EscapeFromCorporate {
                $runner = { param($s, $d) [pscustomobject]@{ ExitCode = 1; Lines = @('                               8        C:\a\um.txt') } }
                $r = Test-EfcCopyIntegrity -SourcePath 'C:\a' -DestinationPath 'C:\b' -RobocopyRunner $runner
                $r.MismatchCount | Should -Be 1
                $r.PendingBytes  | Should -Be 8
            }
        }

        It 'fails closed when the exit code is divergent but the output is unparseable' {
            InModuleScope EscapeFromCorporate {
                $runner = { param($s, $d) [pscustomobject]@{ ExitCode = 1; Lines = @('something nobody expected') } }
                (Test-EfcCopyIntegrity -SourcePath 'C:\a' -DestinationPath 'C:\b' -RobocopyRunner $runner).MismatchCount | Should -BeGreaterOrEqual 1
            }
        }

        It 'treats exit code <Code> as divergent' -ForEach @(@{ Code = 3 }, @{ Code = 4 }, @{ Code = 8 }, @{ Code = 16 }, @{ Code = -1 }) {
            InModuleScope EscapeFromCorporate -Parameters @{ Code = $Code } {
                param($Code)
                $runner = { param($s, $d) [pscustomobject]@{ ExitCode = $Code; Lines = @() } }.GetNewClosure()
                (Test-EfcCopyIntegrity -SourcePath 'C:\a' -DestinationPath 'C:\b' -RobocopyRunner $runner).MismatchCount | Should -BeGreaterOrEqual 1
            }
        }

        It 'ignores extras at the destination (exit 2 only)' {
            InModuleScope EscapeFromCorporate {
                $runner = { param($s, $d) [pscustomobject]@{ ExitCode = 2; Lines = @() } }
                (Test-EfcCopyIntegrity -SourcePath 'C:\a' -DestinationPath 'C:\b' -RobocopyRunner $runner).MismatchCount | Should -Be 0
            }
        }

        It 'rejects a runner that does not follow the ExitCode/Lines contract' {
            InModuleScope EscapeFromCorporate {
                { Test-EfcCopyIntegrity -SourcePath 'C:\a' -DestinationPath 'C:\b' -RobocopyRunner { param($s, $d) @('x') } } | Should -Throw
            }
        }
    }

    Context 'Real robocopy.exe (Windows only)' -Tag 'RealRobocopy' {

        It 'goes from divergent to identical after a real copy' -Skip:(-not (Test-Path (Join-Path $env:SystemRoot 'System32\robocopy.exe'))) {
            $src = Join-Path $TestDrive 'a'
            $dst = Join-Path $TestDrive 'b'
            New-Item -ItemType Directory -Path (Join-Path $src 'sub dir') -Force | Out-Null
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $src 'um.txt') -Value 'abc'
            Set-Content -LiteralPath (Join-Path $src 'sub dir\dois.txt') -Value ('x' * 2000)

            InModuleScope EscapeFromCorporate -Parameters @{ Src = $src; Dst = $dst } {
                param($Src, $Dst)
                $before = Test-EfcCopyIntegrity -SourcePath $Src -DestinationPath $Dst
                $before.MismatchCount | Should -BeGreaterOrEqual 1
                $before.PendingFiles  | Should -Be 2

                $robo = Join-Path $env:SystemRoot 'System32\robocopy.exe'
                & $robo $Src $Dst /E /NJH /NJS /NP /NFL /NDL | Out-Null

                $after = Test-EfcCopyIntegrity -SourcePath $Src -DestinationPath $Dst
                $after.ExitCode      | Should -Be 0
                $after.MismatchCount | Should -Be 0
            }
        }
    }
}
