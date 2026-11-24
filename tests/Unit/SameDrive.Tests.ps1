#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Same-drive guard. ASCII-only on purpose. Aliases (subst, mapped drive, junction)
# are simulated through an injected resolver, so the suite needs no real aliases.

BeforeDiscovery {
    $script:KeyCases = @(
        @{ Path = 'C:\Data\x';                 Key = 'C:' }
        @{ Path = 'c:\';                       Key = 'C:' }
        @{ Path = '\\?\C:\x';                  Key = 'C:' }
        @{ Path = '\\nas\Backup\x';            Key = '\\NAS\BACKUP' }
        @{ Path = '\\?\UNC\nas\backup\x';      Key = '\\NAS\BACKUP' }
        @{ Path = '\\localhost\c$\Users';      Key = 'C:' }
        @{ Path = '\\MEUPC\D$';                Key = 'D:' }
        @{ Path = '\\outro\c$';                Key = '\\OUTRO\C$' }
        @{ Path = '\\localhost\docs';          Key = '\\LOCALHOST\DOCS' }
    )
    $script:RelationCases = @(
        @{ Name = 'same drive';              S = 'C:\Users\a\Docs'; D = 'C:\Backup';          Same = $true  }
        @{ Name = 'same drive, other case';  S = 'c:\a';            D = 'C:\b';               Same = $true  }
        @{ Name = 'different drives';        S = 'C:\a';            D = 'D:\b';               Same = $false }
        @{ Name = 'local to NAS';            S = 'C:\a';            D = '\\NAS\backup\efc';   Same = $false }
        @{ Name = 'same share';              S = '\\NAS\Docs\a';    D = '\\nas\docs\b';       Same = $true  }
        @{ Name = 'same server, other share'; S = '\\NAS\docs\a';   D = '\\NAS\backup\b';     Same = $false }
        @{ Name = 'local admin share';       S = 'C:\a';            D = '\\localhost\c$\b';   Same = $true  }
    )
}

Describe 'same-drive guard' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    Context 'ConvertTo-EfcDriveKey' {
        It 'maps <Path> to <Key>' -ForEach $script:KeyCases {
            InModuleScope EscapeFromCorporate -Parameters @{ Path = $Path; Key = $Key } {
                param($Path, $Key)
                ConvertTo-EfcDriveKey -Path $Path -LocalNames @('localhost', 'MEUPC') | Should -BeExactly $Key
            }
        }

        It 'returns null when no drive or share can be determined' {
            InModuleScope EscapeFromCorporate {
                ConvertTo-EfcDriveKey -Path 'foo\bar' | Should -BeNullOrEmpty
                ConvertTo-EfcDriveKey -Path '\\srv'   | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Test-EfcSameDrive' {
        It '<Name>' -ForEach $script:RelationCases {
            InModuleScope EscapeFromCorporate -Parameters @{ S = $S; D = $D; Same = $Same } {
                param($S, $D, $Same)
                $r = Test-EfcSameDrive -SourcePath $S -DestinationPath $D -PathResolver { param($p) $p } -LocalNames @('localhost')
                $r.Same | Should -Be $Same
            }
        }

        It 'sees through a subst drive that points into the destination drive' {
            InModuleScope EscapeFromCorporate {
                $resolver = { param($p) if ($p -eq 'X:\data') { 'C:\Temp\data' } else { $p } }
                $r = Test-EfcSameDrive -SourcePath 'X:\data' -DestinationPath 'C:\Backup' -PathResolver $resolver
                $r.Same          | Should -BeTrue
                $r.SourceAliased | Should -BeTrue
                $r.SourceFinal   | Should -BeExactly 'C:\Temp\data'
            }
        }

        It 'sees through a junction used as the destination' {
            InModuleScope EscapeFromCorporate {
                $resolver = { param($p) if ($p -eq 'D:\link') { 'C:\target' } else { $p } }
                (Test-EfcSameDrive -SourcePath 'C:\a' -DestinationPath 'D:\link' -PathResolver $resolver).Same | Should -BeTrue
            }
        }

        It 'does not call it the same drive when a drive is mapped to a different share' {
            InModuleScope EscapeFromCorporate {
                $resolver = { param($p) if ($p -eq 'Z:\w') { '\\?\UNC\NAS\share\w' } else { $p } }
                (Test-EfcSameDrive -SourcePath 'C:\a' -DestinationPath 'Z:\w' -PathResolver $resolver).Same | Should -BeFalse
            }
        }

        It 'reports Unknown, not Same, when the drive cannot be determined' {
            InModuleScope EscapeFromCorporate {
                $r = Test-EfcSameDrive -SourcePath 'rel\a' -DestinationPath 'C:\b' -PathResolver { param($p) $p }
                $r.Same     | Should -BeFalse
                $r.Relation | Should -Be 'Unknown'
            }
        }

        It 'falls back to the textual comparison when the resolver throws' {
            InModuleScope EscapeFromCorporate {
                (Test-EfcSameDrive -SourcePath 'C:\a' -DestinationPath 'C:\b' -PathResolver { param($p) throw 'boom' }).Same | Should -BeTrue
            }
        }
    }

    Context 'Test-EfcPreflight guard 4' {
        BeforeEach {
            $script:src = Join-Path $TestDrive 'src'
            $script:dst = Join-Path $TestDrive 'dst'
            New-Item -ItemType Directory -Path $script:src, $script:dst -Force | Out-Null
        }

        It 'refuses a destination on the same drive and names the override' {
            InModuleScope EscapeFromCorporate -Parameters @{ S = $script:src; D = $script:dst } {
                param($S, $D)
                $resolver = { param($p) if ($p -eq $S) { 'C:\data' } else { 'C:\backup' } }.GetNewClosure()
                $p = Test-EfcPreflight -SourcePath $S -DestinationPath $D -PathResolver $resolver
                $p.IsValid | Should -BeFalse
                ($p.Messages -join ' ') | Should -Match 'same drive'
                ($p.Messages -join ' ') | Should -Match '-AllowSameDrive'
            }
        }

        It 'accepts the same drive with -AllowSameDrive' {
            InModuleScope EscapeFromCorporate -Parameters @{ S = $script:src; D = $script:dst } {
                param($S, $D)
                $resolver = { param($p) if ($p -eq $S) { 'C:\data' } else { 'C:\backup' } }.GetNewClosure()
                (Test-EfcPreflight -SourcePath $S -DestinationPath $D -AllowSameDrive -PathResolver $resolver).IsValid | Should -BeTrue
            }
        }

        It 'still refuses a self-copy revealed only by aliases, even with -AllowSameDrive' {
            InModuleScope EscapeFromCorporate -Parameters @{ S = $script:src; D = $script:dst } {
                param($S, $D)
                $same     = { param($p) 'C:\data' }
                $nested   = { param($p) if ($p -like '*src') { 'C:\data' } else { 'C:\data\sub' } }
                (Test-EfcPreflight -SourcePath $S -DestinationPath $D -AllowSameDrive -PathResolver $same).IsValid   | Should -BeFalse
                (Test-EfcPreflight -SourcePath $S -DestinationPath $D -AllowSameDrive -PathResolver $nested).IsValid | Should -BeFalse
            }
        }

        It 'accepts a network share destination' {
            InModuleScope EscapeFromCorporate -Parameters @{ S = $script:src; D = $script:dst } {
                param($S, $D)
                $resolver = { param($p) if ($p -like '*src') { 'C:\data' } else { '\\NAS\share\x' } }
                $p = Test-EfcPreflight -SourcePath $S -DestinationPath $D -PathResolver $resolver
                $p.IsValid | Should -BeTrue
                $p.Messages.Count | Should -Be 0
            }
        }
    }
}
