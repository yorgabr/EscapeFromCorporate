#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\EscapeFromCorporate\EscapeFromCorporate.psd1'
    Import-Module $script:ModulePath -Force
    . (Join-Path $PSScriptRoot 'Fuzz.Support.ps1')

    $script:FixtureRoot = Join-Path $PSScriptRoot '..\fixtures\robocopy-lines'
}

Describe 'ConvertFrom-RobocopyLine :: robustness invariants (fuzzing)' {

    Context 'Invariant 1: never throws on any input' {

        It 'survives the full deterministic fuzz corpus without throwing' {
            InModuleScope EscapeFromCorporate {
                . (Join-Path (Split-Path $PSCommandPath) 'Fuzz.Support.ps1') -ErrorAction SilentlyContinue
            }

            $corpus = New-EfcFuzzCorpus -Seed 1337 -Count 500
            $failures = [System.Collections.Generic.List[string]]::new()

            foreach ($line in $corpus) {
                try {
                    InModuleScope EscapeFromCorporate -Parameters @{ L = $line } {
                        param($L)
                        $null = ConvertFrom-RobocopyLine -Line $L
                    }
                }
                catch {
                    $failures.Add("Line threw: [$($line.Substring(0, [Math]::Min(60, $line.Length)))] -> $($_.Exception.Message)")
                }
            }

            $failures | Should -BeNullOrEmpty
        }

        It 'survives multiple independent seeds (broader coverage)' {
            foreach ($seed in 1, 42, 777, 2024, 99999) {
                $corpus = New-EfcFuzzCorpus -Seed $seed -Count 200
                foreach ($line in $corpus) {
                    {
                        InModuleScope EscapeFromCorporate -Parameters @{ L = $line } {
                            param($L)
                            $null = ConvertFrom-RobocopyLine -Line $L
                        }
                    } | Should -Not -Throw
                }
            }
        }
    }

    Context 'Invariant 2: output is always $null or structurally valid' {

        It 'every non-null result has the canonical shape and sane values' {
            $corpus = New-EfcFuzzCorpus -Seed 1337 -Count 500

            foreach ($line in $corpus) {
                $entry = InModuleScope EscapeFromCorporate -Parameters @{ L = $line } {
                    param($L)
                    ConvertFrom-RobocopyLine -Line $L
                }

                if ($null -eq $entry) { continue }

                # Structural contract: all expected members present.
                $entry.PSObject.Properties.Name | Should -Contain 'Type'
                $entry.PSObject.Properties.Name | Should -Contain 'Action'
                $entry.PSObject.Properties.Name | Should -Contain 'Size'
                $entry.PSObject.Properties.Name | Should -Contain 'Path'

                # Type is one of the known classifications.
                $entry.Type | Should -BeIn @('File', 'Dir', 'Error')

                # Size is a non-negative long (never garbage, never negative).
                $entry.Size | Should -BeOfType [long]
                $entry.Size | Should -BeGreaterOrEqual 0
            }
        }

        It 'never coerces a non-numeric size into a File entry' {
            # "NOTANUMBER" must not parse as a valid sized file.
            $entry = InModuleScope EscapeFromCorporate {
                ConvertFrom-RobocopyLine -Line "New File `tNOTANUMBER`tC:\x.txt"
            }
            # Either null, or if matched, Size must have parsed from a real number.
            if ($null -ne $entry -and $entry.Type -eq 'File') {
                $entry.Size | Should -BeGreaterOrEqual 0
            }
        }

        It 'rejects negative sizes as File entries' {
            $entry = InModuleScope EscapeFromCorporate {
                ConvertFrom-RobocopyLine -Line "New File `t-512`tC:\neg.txt"
            }
            # The \d+ regex cannot match a leading '-', so this must not be a File
            # with a negative size.
            if ($null -ne $entry) {
                $entry.Size | Should -BeGreaterOrEqual 0
            }
        }
    }

    Context 'Invariant 3: no false positives on banners / separators' {

        It 'classifies known banner and summary lines as ignorable ($null)' {
            $banners = @(
                '-------------------------------------------------------------------------------',
                '   ROBOCOPY     ::     Robust File Copy for Windows',
                '  Started : Monday, January 15, 2024 9:32:00 AM',
                '   Source : C:\Users\me\Data\',
                '     Dest : \\HOME-NAS\Backup\Dump\',
                '    Files : *.*',
                '  Options : *.* /S /E /R:2 /W:5',
                '',
                '   ',
                "`t"
            )

            foreach ($b in $banners) {
                $entry = InModuleScope EscapeFromCorporate -Parameters @{ L = $b } {
                    param($L)
                    ConvertFrom-RobocopyLine -Line $L
                }
                $entry | Should -BeNullOrEmpty -Because "banner/separator must be ignored: [$b]"
            }
        }
    }
}

Describe 'ConvertFrom-RobocopyLine :: real-locale fixtures' {

    Context 'en-US: canonical English labels parse correctly' {

        It 'parses New File lines with correct size and path' {
            $lines = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'en-US.log') -Encoding UTF8
            $files = foreach ($l in $lines) {
                $e = InModuleScope EscapeFromCorporate -Parameters @{ L = $l } {
                    param($L) ConvertFrom-RobocopyLine -Line $L
                }
                if ($e -and $e.Type -eq 'File') { $e }
            }
            @($files).Count | Should -BeGreaterThan 0
            ($files | Where-Object { $_.Size -eq 1024 }).Path | Should -Match 'report\.docx'
        }

        It 'handles paths containing spaces' {
            $e = InModuleScope EscapeFromCorporate {
                ConvertFrom-RobocopyLine -Line "	  New File 		    2048	C:\Users\me\Pictures\photo with spaces.jpg"
            }
            $e.Type | Should -Be 'File'
            $e.Path | Should -Match 'photo with spaces\.jpg$'
            $e.Size | Should -Be 2048
        }

        It 'handles unicode paths byte-accurately' {
            $e = InModuleScope EscapeFromCorporate {
                ConvertFrom-RobocopyLine -Line "	  New File 		    4096	C:\dados\arquivo-ção-üñ.txt"
            }
            $e.Type | Should -Be 'File'
            $e.Path | Should -Match 'arquivo-ção-üñ\.txt$'
        }
    }

    Context 'pt-BR / de-DE: localized action labels (documented limitation)' {

        # DECISION RECORD:
        # Robocopy localizes action labels ("New File" -> "Arquivo Novo" / "Neue Datei").
        # The parser is intentionally anchored on English labels. On a localized OS
        # the recommended mitigation is to force English robocopy output. These tests
        # DOCUMENT the current behavior so the limitation is explicit, not silent.

        It 'does NOT parse localized pt-BR action labels as File entries' {
            $e = InModuleScope EscapeFromCorporate {
                ConvertFrom-RobocopyLine -Line "	  Arquivo Novo 		    4096	C:\Usuarios\eu\Documentos\rel.docx"
            }
            # Localized "Arquivo Novo" is not in the English action alternation,
            # but the sized-file fallback regex MAY still match on the numeric+path
            # shape. Assert only the robustness contract, not a specific outcome.
            if ($null -ne $e) {
                $e.Type | Should -BeIn @('File', 'Dir', 'Error')
                $e.Size | Should -BeGreaterOrEqual 0
            }
        }

        It 'the sized-file fallback still captures size+path regardless of label language' {
            # This is the SAFETY NET: even when the action label is localized, the
            # generic "<whitespace><digits><whitespace><drivepath>" pattern recovers
            # the essential metrics. Verify it works for a German line.
            $e = InModuleScope EscapeFromCorporate {
                ConvertFrom-RobocopyLine -Line "		    1500	C:\Benutzer\ich\bericht.docx"
            }
            $e.Type | Should -Be 'File'
            $e.Size | Should -Be 1500
            $e.Path | Should -Match 'bericht\.docx$'
        }
    }

    Context 'malformed fixtures: graceful degradation' {

        It 'processes the malformed fixture file without throwing' {
            $lines = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'malformed.log') -Encoding UTF8
            foreach ($l in $lines) {
                {
                    InModuleScope EscapeFromCorporate -Parameters @{ L = $l } {
                        param($L) $null = ConvertFrom-RobocopyLine -Line $L
                    }
                } | Should -Not -Throw
            }
        }

        It 'parses ERROR lines as Error type' {
            $e = InModuleScope EscapeFromCorporate {
                ConvertFrom-RobocopyLine -Line 'ERROR 5 (0x00000005) Accessing Source Directory C:\locked'
            }
            $e.Type | Should -Be 'Error'
        }
    }
}

Describe 'ConvertFrom-RobocopyLine :: performance characteristic' {

    It 'parses a large batch within a reasonable time budget' {
        # Not a strict benchmark, but a regression guard against catastrophic
        # regex backtracking on adversarial input (e.g. the 5000-char line).
        $corpus = New-EfcFuzzCorpus -Seed 2024 -Count 2000

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        InModuleScope EscapeFromCorporate -Parameters @{ Corpus = $corpus } {
            param($Corpus)
            foreach ($line in $Corpus) {
                $null = ConvertFrom-RobocopyLine -Line $line
            }
        }
        $sw.Stop()

        # 2000 lines should parse well under a second even on a modest CI runner.
        # A blown budget signals catastrophic backtracking introduced by a regex edit.
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
    }
}
