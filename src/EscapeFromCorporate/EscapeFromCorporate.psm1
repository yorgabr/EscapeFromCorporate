#Requires -Version 5.1
<#
    Escape From Corporate - root module loader.
    Dot-sources Private then Public functions and exports only the public surface.
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0

    NOTE: this file intentionally avoids backtick (`) line-continuation
    characters entirely. A backtick followed by invisible trailing
    whitespace (or a stray CR from mixed line endings) before the real
    newline is parsed as an escaped-whitespace character rather than a
    continuation, which can make PowerShell try to *execute* the dangling
    remainder as a command - producing a runtime "term not recognized"
    error that static analysis (PSScriptAnalyzer) will not catch, since
    the file still parses as syntactically valid PowerShell. Using
    intermediate variables and natural pipeline breaks (a `|` at end of
    line needs no backtick) sidesteps the whole class of bug.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = $PSScriptRoot

# Load Private first (engine dependencies), then Public. Sorted for deterministic,
# reproducible load order across filesystems and PowerShell versions.
$privateItems = Get-ChildItem -Path (Join-Path $moduleRoot 'Private') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue
$private = @($privateItems | Sort-Object FullName)

$publicItems = Get-ChildItem -Path (Join-Path $moduleRoot 'Public') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue
$public = @($publicItems | Sort-Object FullName)

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to import function $($file.FullName): $($_.Exception.Message)"
    }
}

# Export only the public function names.
$exportedAliases = @('efc', 'Escape-FromCorporate', 'Invoke-Efc')
Export-ModuleMember -Function $public.BaseName -Alias $exportedAliases