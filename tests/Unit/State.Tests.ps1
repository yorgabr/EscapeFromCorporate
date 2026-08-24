#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'State persistence (Write/Get round-trip)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    It 'writes and reads back an equivalent state object' {
        InModuleScope EscapeFromCorporate -Parameters @{ Root = $script:Root } {
            param($Root)

            $state = New-EfcState -SourcePath 'C:\src' -DestinationPath '\\NAS\dst' `
                -LogPath (Join-Path $Root 'job.log')

            Write-EfcState -State $state -StateRoot $Root
            $loaded = Get-EfcState -StateRoot $Root

            $loaded.jobId                     | Should -Be $state.jobId
            $loaded.signatures.combinedKey    | Should -Be $state.signatures.combinedKey
            $loaded.schemaVersion             | Should -Be $state.schemaVersion
        }
    }

    It 'returns $null when no state exists' {
        InModuleScope EscapeFromCorporate -Parameters @{ Root = $script:Root } {
            param($Root)
            Get-EfcState -StateRoot $Root | Should -BeNullOrEmpty
        }
    }

    It 'recovers from the temp sidecar when primary is missing' {
        InModuleScope EscapeFromCorporate -Parameters @{ Root = $script:Root } {
            param($Root)

            $state = New-EfcState -SourcePath 'C:\a' -DestinationPath 'C:\b' `
                -LogPath 'x.log'
            New-Item -ItemType Directory -Path $Root -Force | Out-Null

            # Simulate a crash: only the .tmp exists.
            $json = $state | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText(
                (Join-Path $Root 'state.json.tmp'), $json,
                [System.Text.UTF8Encoding]::new($false))

            (Get-EfcState -StateRoot $Root).jobId | Should -Be $state.jobId
        }
    }

    It 'produces stable signatures for equivalent paths' {
        InModuleScope EscapeFromCorporate {
            $a = Get-EfcSignature -Path 'C:\Data\'
            $b = Get-EfcSignature -Path 'c:\data'
            $a.Hash | Should -Be $b.Hash
        }
    }

    It 'produces stable signatures across mixed path separators' {
        InModuleScope EscapeFromCorporate {
            $a = Get-EfcSignature -Path 'C:\Data\Sub'
            $c = Get-EfcSignature -Path 'C:/Data/Sub'
            $a.Hash | Should -Be $c.Hash
        }
    }

    It 'includes hashing validation fields at schema 1.1.0' {
        InModuleScope EscapeFromCorporate {
            $state = New-EfcState -SourcePath 'C:\a' -DestinationPath 'C:\b' -LogPath 'l.log'
            $state.schemaVersion                                        | Should -Be '1.1.0'
            $state.validation.PSObject.Properties.Name | Should -Contain 'sampleHashCount'
            $state.validation.PSObject.Properties.Name | Should -Contain 'hashSamplesChecked'
            $state.validation.PSObject.Properties.Name | Should -Contain 'hashMismatches'
            $state.validation.sampleHashCount                          | Should -Be 0
        }
    }
}

Describe 'Resolve-EfcResumption (decision matrix)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    It 'returns FreshStart when no prior state' {
        InModuleScope EscapeFromCorporate {
            (Resolve-EfcResumption -ExistingState $null `
                -SourcePath 'C:\a' -DestinationPath 'C:\b').Decision |
                Should -Be 'FreshStart'
        }
    }

    It 'returns ForceRestart when -Force is set regardless of state' {
        InModuleScope EscapeFromCorporate {
            $prior = New-EfcState -SourcePath 'C:\a' -DestinationPath 'C:\b' -LogPath 'l.log'
            (Resolve-EfcResumption -ExistingState $prior `
                -SourcePath 'C:\a' -DestinationPath 'C:\b' -Force).Decision |
                Should -Be 'ForceRestart'
        }
    }

    It 'returns Conflict when signatures differ' {
        InModuleScope EscapeFromCorporate {
            $prior = New-EfcState -SourcePath 'C:\old' -DestinationPath 'C:\dst' -LogPath 'l.log'
            (Resolve-EfcResumption -ExistingState $prior `
                -SourcePath 'C:\new' -DestinationPath 'C:\dst').Decision |
                Should -Be 'Conflict'
        }
    }

    It 'returns AlreadyCompleted for a matching finished job' {
        InModuleScope EscapeFromCorporate {
            $prior = New-EfcState -SourcePath 'C:\a' -DestinationPath 'C:\b' -LogPath 'l.log'
            $prior.status = 'Completed'
            (Resolve-EfcResumption -ExistingState $prior `
                -SourcePath 'C:\a' -DestinationPath 'C:\b').Decision |
                Should -Be 'AlreadyCompleted'
        }
    }
}

Describe 'Test-EfcResumePointer (boundary integrity)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    BeforeEach {
        $script:Log = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.log')
        [System.IO.File]::WriteAllText($script:Log,
            "line one`nline two`n",
            [System.Text.UTF8Encoding]::new($false))
    }

    It 'accepts offset 0' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log } {
            param($Log)
            Test-EfcResumePointer -LogPath $Log -ByteOffset 0 | Should -BeTrue
        }
    }

    It 'accepts an offset landing right after a newline' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log } {
            param($Log)
            # "line one\n" == 9 bytes; offset 9 sits at start of "line two".
            Test-EfcResumePointer -LogPath $Log -ByteOffset 9 | Should -BeTrue
        }
    }

    It 'rejects an offset mid-line' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log } {
            param($Log)
            Test-EfcResumePointer -LogPath $Log -ByteOffset 4 | Should -BeFalse
        }
    }

    It 'rejects an offset past EOF' {
        InModuleScope EscapeFromCorporate -Parameters @{ Log = $script:Log } {
            param($Log)
            Test-EfcResumePointer -LogPath $Log -ByteOffset 9999 | Should -BeFalse
        }
    }
}

Describe 'Test-EfcPreflight (enumeration & safety guards)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    It 'aggregates file counts and bytes from a mocked list pass' {
        # Source must exist for the guard to pass; point at TestDrive.
        $src = Join-Path $TestDrive 'src'
        New-Item -ItemType Directory -Path $src -Force | Out-Null

        InModuleScope EscapeFromCorporate -Parameters @{ Src = $src } {
            param($Src)

            $fakeRunner = {
                param($Source, $Dest)
                @(
                    "New File `t1000`tC:\src\a.txt",
                    "New File `t2500`tC:\src\b.txt",
                    "`tNew Dir `t`tC:\src\sub"
                )
            }

            $result = Test-EfcPreflight -SourcePath $Src -DestinationPath 'C:\dst' `
                -Enumerate -RobocopyRunner $fakeRunner

            $result.TotalFiles | Should -Be 2
            $result.TotalBytes | Should -Be 3500
        }
    }

    It 'rejects blank or whitespace-only paths' {
        InModuleScope EscapeFromCorporate {
            $result = Test-EfcPreflight -SourcePath '   ' -DestinationPath 'C:\dst'
            $result.IsValid | Should -BeFalse
            $result.Messages -join ' ' | Should -Match 'blank'
        }
    }

    It 'rejects when source and destination resolve to the same path' {
        $src = Join-Path $TestDrive 'same'
        New-Item -ItemType Directory -Path $src -Force | Out-Null

        InModuleScope EscapeFromCorporate -Parameters @{ Src = $src } {
            param($Src)

            $result = Test-EfcPreflight -SourcePath $Src -DestinationPath "$Src\"
            $result.IsValid | Should -BeFalse
            $result.Messages -join ' ' | Should -Match 'same path'
        }
    }

    It 'rejects when the effective destination is nested inside the source' {
        $src = Join-Path $TestDrive 'nestsrc'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $nestedDest = Join-Path $src 'Sub'

        InModuleScope EscapeFromCorporate -Parameters @{ Src = $src; NestedDest = $nestedDest } {
            param($Src, $NestedDest)

            $result = Test-EfcPreflight -SourcePath $Src -DestinationPath $NestedDest
            $result.IsValid | Should -BeFalse
            $result.Messages -join ' ' | Should -Match 'nested inside source'
        }
    }

    It 'rejects when the local destination drive is unavailable' {
        $src = Join-Path $TestDrive 'validsrc'
        New-Item -ItemType Directory -Path $src -Force | Out-Null

        InModuleScope EscapeFromCorporate -Parameters @{ Src = $src } {
            param($Src)

            # Q: is exceedingly unlikely to be mapped on a CI/dev runner.
            $result = Test-EfcPreflight -SourcePath $Src -DestinationPath 'Q:\NoSuchDrive\Dump'
            $result.IsValid | Should -BeFalse
            $result.Messages -join ' ' | Should -Match 'drive is not available'
        }
    }
}

Describe 'Resolve-EfcEffectiveDestination (rsync-style trailing-slash semantics)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    It 'copies contents directly (no nesting) when Source ends with a backslash' {
        InModuleScope EscapeFromCorporate {
            Resolve-EfcEffectiveDestination -Source 'C:\Data\' -Destination '\\NAS\Dump' |
                Should -Be '\\NAS\Dump'
        }
    }

    It 'copies contents directly (no nesting) when Source ends with a forward slash' {
        InModuleScope EscapeFromCorporate {
            Resolve-EfcEffectiveDestination -Source 'C:\Data/' -Destination '\\NAS\Dump' |
                Should -Be '\\NAS\Dump'
        }
    }

    It 'nests Source as a subfolder of Destination when there is no trailing separator' {
        InModuleScope EscapeFromCorporate {
            Resolve-EfcEffectiveDestination -Source 'C:\Data' -Destination '\\NAS\Dump' |
                Should -Be (Join-Path '\\NAS\Dump' 'Data')
        }
    }

    It 'falls back to Destination unchanged for a degenerate drive-root Source' {
        InModuleScope EscapeFromCorporate {
            # Regression guard: 'C:' is a Windows drive-relative path, not an
            # opaque/empty string. A naive Split-Path -Leaf on it resolves
            # against the CURRENT WORKING DIRECTORY on that drive for this
            # PowerShell session - e.g. it can return the project folder's
            # own name - rather than any property of the literal string 'C:'.
            # This must be caught explicitly before Split-Path is ever called.
            Resolve-EfcEffectiveDestination -Source 'C:' -Destination '\\NAS\Dump' |
                Should -Be '\\NAS\Dump'
        }
    }

    It 'falls back to Destination unchanged for a bare UNC server root' {
        InModuleScope EscapeFromCorporate {
            Resolve-EfcEffectiveDestination -Source '\\SERVER' -Destination '\\NAS\Dump' |
                Should -Be '\\NAS\Dump'
        }
    }

    It 'falls back to Destination unchanged for a bare UNC share root' {
        InModuleScope EscapeFromCorporate {
            Resolve-EfcEffectiveDestination -Source '\\SERVER\Share' -Destination '\\NAS\Dump' |
                Should -Be '\\NAS\Dump'
        }
    }
    
    It 'nests the last segment of a deep UNC source' {
        InModuleScope EscapeFromCorporate {
            # Destination is intentionally a UNC path here, not a drive letter
            # (e.g. 'D:\Backup'). Join-Path is provider-aware and resolves the
            # drive through a PSDrive - on any machine/runner without a D:
            # drive attached, Join-Path itself throws DriveNotFoundException,
            # independent of anything Resolve-EfcEffectiveDestination does.
            Resolve-EfcEffectiveDestination -Source '\\SERVER\Share\Projects\Alpha' -Destination '\\NAS\Dump' |
                Should -Be (Join-Path '\\NAS\Dump' 'Alpha')
        }
    }

    It 'nests correctly when Source uses forward separators internally' {
        InModuleScope EscapeFromCorporate {
            Resolve-EfcEffectiveDestination -Source 'C:/Data/Sub' -Destination '\\NAS\Dump' |
                Should -Be (Join-Path '\\NAS\Dump' 'Sub')
        }
    }

    It 'nests a bare relative source name' {
        InModuleScope EscapeFromCorporate {
            Resolve-EfcEffectiveDestination -Source 'Data' -Destination '\\NAS\Dump' |
                Should -Be (Join-Path '\\NAS\Dump' 'Data')
        }
    }

    It 'is deterministic for a drive-relative source (no $PWD dependency)' {
        InModuleScope EscapeFromCorporate {
            # Regression guard: must NOT consult the session's working directory.
            Resolve-EfcEffectiveDestination -Source 'C:Data' -Destination '\\NAS\Dump' |
                Should -Be (Join-Path '\\NAS\Dump' 'Data')
        }
    }

    It 'never throws for adversarial source shapes' -ForEach @(
        'C:', 'C:', 'C:\', '\\S', '\\S\Sh', '\\S\Sh', 'Data', 'C:Data', 'C:\Data\'
    ) {
        InModuleScope EscapeFromCorporate -Parameters @{ S = $_ } {
            param($S)
            { Resolve-EfcEffectiveDestination -Source $S -Destination '\\NAS\Dump' } | Should -Not -Throw
        }
    }
}

Describe 'Get-EfcPathRoot' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1') -Force
    }

    It 'resolves the drive root of a local path' {
        InModuleScope EscapeFromCorporate {
            Get-EfcPathRoot -Path 'C:\Data\Sub\Deep' | Should -Be 'C:\'
        }
    }

    It 'resolves the share root of a UNC path' {
        InModuleScope EscapeFromCorporate {
            Get-EfcPathRoot -Path '\\NAS\Dump\Deep\Nested' | Should -Be '\\NAS\Dump'
        }
    }
}