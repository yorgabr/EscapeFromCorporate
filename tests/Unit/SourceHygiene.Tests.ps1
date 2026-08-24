#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Source hygiene: illegal cmdlet parameter-set combinations' {

    It 'never combines Split-Path -LiteralPath with a mode switch' {
        # -LiteralPath lives in an exclusive parameter set that declares NONE of
        # the mode switches; the combination is a terminating binding error that
        # PSScriptAnalyzer cannot detect and -ErrorAction cannot suppress.
        $pattern = 'Split-Path(?=[^\r\n]*-Lit)(?=[^\r\n]*-(Leaf|Parent|Qualifier|NoQualifier|Extension|LeafBase|IsAbsolute))'

        $hits = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\..\src') -Recurse -Filter '*.ps1' -File |
            Select-String -Pattern $pattern

        $hits | Should -BeNullOrEmpty -Because (
            'Split-Path -LiteralPath cannot be combined with -Leaf/-Parent/etc. ' +
            'Use pure string extraction instead (see Resolve-EfcEffectiveDestination).'
        )
    }
}