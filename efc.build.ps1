#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-Build pipeline definition for the Escape From Corporate module.

.DESCRIPTION
    Defines the local CI/CD tasks: Bootstrap, Lint, Test, Package, and Clean.
    Task dependencies are strictly enforced: Test requires Lint; Package requires Test.
    Designed to run identically on a developer laptop and in GitHub Actions.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
    Invoke via: Invoke-Build -File efc.build.ps1 <TaskName>
    Layout  : this script lives at the PROJECT ROOT (not under .\build\).
              ProjectRoot == BuildRoot == $PSScriptRoot in this repository.
#>

# ------------------------------------------------------------------------------
# Path anchoring
# ------------------------------------------------------------------------------
# efc.build.ps1 lives at the project root in this repository layout, so
# ProjectRoot IS BuildRoot - there is no "build\" subfolder to climb out of.
# (Do NOT use Split-Path -Parent here; that was a leftover assumption from a
# layout where this script lived one level down, e.g. .\build\efc.build.ps1,
# and it silently resolves one directory too high, breaking every path below.)
$BuildRoot    = $PSScriptRoot
$ProjectRoot  = $BuildRoot
$ModulesRoot  = Join-Path $BuildRoot 'modules'
$SourceRoot   = Join-Path $ProjectRoot 'src\EscapeFromCorporate'
$TestsRoot    = Join-Path $ProjectRoot 'tests'
$ArtifactDir  = Join-Path $ProjectRoot 'artifacts'
$ManifestPath = Join-Path $SourceRoot 'EscapeFromCorporate.psd1'

# ------------------------------------------------------------------------------
# Ensure vendored modules are discoverable for every task in this session.
# ------------------------------------------------------------------------------
$sep = [System.IO.Path]::PathSeparator
if (($env:PSModulePath -split $sep) -notcontains $ModulesRoot) {
    $env:PSModulePath = $ModulesRoot + $sep + $env:PSModulePath
}

# ==============================================================================
# TASK: Bootstrap
# Guarantees Invoke-Build, Pester 5+, and PSScriptAnalyzer are vendored locally.
# ==============================================================================
task Bootstrap {
    # NOTE: the dependency bootstrapper lives under .\tools in this repository
    # layout (not .\bootstrap, as older docs/scaffolding assumed).
    $bootstrapper = Join-Path $BuildRoot 'tools\Install-BuildDependencies.ps1'

    if (-not (Test-Path -LiteralPath $bootstrapper)) {
        throw "Bootstrap script not found at: $bootstrapper. Verify the file exists under .\tools."
    }

    Write-Build Cyan "Running zero-admin bootstrap: $bootstrapper"
    & $bootstrapper -Verbose:($VerbosePreference -eq 'Continue')
}

# ==============================================================================
# TASK: Lint
# Static analysis via PSScriptAnalyzer. Depends on Bootstrap.
# ==============================================================================
task Lint Bootstrap, {
    Import-Module PSScriptAnalyzer -MinimumVersion '1.21.0' -Force

    $settingsPath = Join-Path $TestsRoot 'PSScriptAnalyzerSettings.psd1'

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source root not found: $SourceRoot. Check `$ProjectRoot/`$SourceRoot path anchoring in efc.build.ps1."
    }
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw "PSScriptAnalyzer settings not found: $settingsPath."
    }

    Write-Build Cyan "Analyzing source with settings: $settingsPath"

    # NOTE: deliberately NOT calling `Invoke-ScriptAnalyzer -Path $SourceRoot
    # -Recurse` in one shot. The PSUseCompatibleSyntax rule (enabled in
    # PSScriptAnalyzerSettings.psd1) keeps mutable internal state while
    # building its per-target-version syntax compatibility map, and a
    # recursive multi-file scan can mutate that state while it is still being
    # enumerated internally - PSScriptAnalyzer itself then throws "Coleção foi
    # modificada; talvez a operação de enumeração não seja executada"
    # (Collection was modified). This is a known upstream fragility, not a
    # bug in this project's source. Analyzing one file per call sidesteps the
    # concurrent-enumeration scenario entirely while preserving full coverage
    # and the same aggregated result shape the rest of this task expects.
    $sourceFiles = Get-ChildItem -Path $SourceRoot -Recurse -Filter '*.ps1' -File
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($file in $sourceFiles) {
        $fileResults = Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsPath
        if ($fileResults) {
            foreach ($r in $fileResults) { $results.Add($r) }
        }
    }

    if ($results.Count -gt 0) {
        $results | Format-Table -AutoSize | Out-String | Write-Build Yellow

        $errors = @($results | Where-Object Severity -eq 'Error')
        if ($errors.Count -gt 0) {
            throw "PSScriptAnalyzer reported $($errors.Count) error-severity finding(s)."
        }
        Write-Build Yellow "Lint completed with warnings (non-blocking)."
    }
    else {
        Write-Build Green "Lint clean: no findings."
    }
}

# ==============================================================================
# TASK: Test
# Pester 5+ suites. STRICT dependency: Lint must pass before tests run.
# ==============================================================================
task Test Lint, {
    Import-Module Pester -MinimumVersion '5.5.0' -Force

    if (-not (Test-Path $ArtifactDir)) {
        New-Item -ItemType Directory -Path $ArtifactDir -Force | Out-Null
    }

    $config = New-PesterConfiguration
    $config.Run.Path         = $TestsRoot
    $config.Run.PassThru     = $true
    $config.Output.Verbosity = 'Detailed'

    # Code coverage over the module source.
    $config.CodeCoverage.Enabled    = $true
    $config.CodeCoverage.Path       = $SourceRoot
    $config.CodeCoverage.OutputPath = Join-Path $ArtifactDir 'coverage.xml'
    $config.CodeCoverage.OutputFormat = 'JaCoCo'

    # NUnit test results for CI ingestion.
    $config.TestResult.Enabled    = $true
    $config.TestResult.OutputPath = Join-Path $ArtifactDir 'testResults.xml'
    $config.TestResult.OutputFormat = 'NUnitXml'

    Write-Build Cyan "Executing Pester suites under: $TestsRoot"
    $result = Invoke-Pester -Configuration $config

    if ($result.FailedCount -gt 0) {
        throw "Pester reported $($result.FailedCount) failing test(s)."
    }
    Write-Build Green "All $($result.PassedCount) test(s) passed."
}

# ==============================================================================
# TASK: Package
# Produces a distributable module folder + zip. STRICT dependency: Test must pass.
# ==============================================================================
task Package Test, Docs, {
    Import-Module (Join-Path $ProjectRoot 'src\EscapeFromCorporate') -Force -ErrorAction SilentlyContinue

    $manifest = Import-PowerShellDataFile -Path $ManifestPath
    $version  = $manifest.ModuleVersion
    $stageDir = Join-Path $ArtifactDir "EscapeFromCorporate\$version"

    Write-Build Cyan "Staging module v$version to: $stageDir"

    if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    # Copy only the publishable module surface (exclude tests, build, vendored deps).
    Copy-Item -Path (Join-Path $SourceRoot '*') -Destination $stageDir -Recurse -Force

    # Bundle LICENSE + NOTICE for Apache 2.0 compliance.
    foreach ($legal in 'LICENSE', 'NOTICE') {
        $srcLegal = Join-Path $ProjectRoot $legal
        if (Test-Path $srcLegal) {
            Copy-Item $srcLegal -Destination $stageDir -Force
        }
    }

    $zipPath = Join-Path $ArtifactDir "EscapeFromCorporate-$version.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        (Split-Path $stageDir -Parent), $zipPath)

    Write-Build Green "Package artifact created: $zipPath"
}

# ==============================================================================
# TASK: Changelog
# Generates CHANGELOG.md from git history using Conventional Commits parsing.
# ==============================================================================
task Changelog {
    $changelogPath = Join-Path $ProjectRoot 'CHANGELOG.md'

    # Pull commits since the last tag (or all if untagged).
    $lastTag = (& git describe --tags --abbrev=0 2>$null)
    $range   = if ($lastTag) { "$lastTag..HEAD" } else { 'HEAD' }

    $raw = & git log $range --pretty=format:'%s|%h|%an|%ad' --date=short 2>$null
    if (-not $raw) {
        Write-Build Yellow 'No commits found for changelog range.'
        return
    }

    # Conventional Commits classification map.
    $sections = [ordered]@{
        'feat'     = 'Features'
        'fix'      = 'Bug Fixes'
        'perf'     = 'Performance'
        'refactor' = 'Refactoring'
        'docs'     = 'Documentation'
        'test'     = 'Tests'
        'build'    = 'Build System'
        'ci'       = 'Continuous Integration'
        'chore'    = 'Chores'
    }
    $buckets = @{}
    foreach ($k in $sections.Keys) { $buckets[$k] = [System.Collections.Generic.List[string]]::new() }
    $other = [System.Collections.Generic.List[string]]::new()

    $rxConv = [regex]'^(?<type>\w+)(\((?<scope>[^)]+)\))?(?<breaking>!)?:\s*(?<desc>.+)$'

    foreach ($entry in $raw) {
        $parts   = $entry -split '\|', 4
        $subject = $parts[0]
        $hash    = $parts[1]

        $m = $rxConv.Match($subject)
        if ($m.Success) {
            $type  = $m.Groups['type'].Value.ToLowerInvariant()
            $scope = $m.Groups['scope'].Value
            $desc  = $m.Groups['desc'].Value
            # ${scope} (not $scope:) — PowerShell parses "$scope:" inside a
            # double-quoted string as an attempted scope/drive qualifier
            # (e.g. $script:, $global:), which throws at runtime.
            $line  = if ($scope) { "- **${scope}:** $desc ($hash)" } else { "- $desc ($hash)" }
            if ($m.Groups['breaking'].Success) { $line = "- **BREAKING:** $desc ($hash)" }

            if ($buckets.ContainsKey($type)) { $buckets[$type].Add($line) }
            else { $other.Add("- $subject ($hash)") }
        }
        else {
            $other.Add("- $subject ($hash)")
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Changelog')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("## $(if ($lastTag) { "Unreleased (since $lastTag)" } else { 'Unreleased' }) - $(Get-Date -Format 'yyyy-MM-dd')")
    [void]$sb.AppendLine()

    foreach ($k in $sections.Keys) {
        if ($buckets[$k].Count -gt 0) {
            [void]$sb.AppendLine("### $($sections[$k])")
            [void]$sb.AppendLine()
            $buckets[$k] | ForEach-Object { [void]$sb.AppendLine($_) }
            [void]$sb.AppendLine()
        }
    }
    if ($other.Count -gt 0) {
        [void]$sb.AppendLine('### Other')
        [void]$sb.AppendLine()
        $other | ForEach-Object { [void]$sb.AppendLine($_) }
        [void]$sb.AppendLine()
    }

    Set-Content -Path $changelogPath -Value $sb.ToString() -Encoding UTF8
    Write-Build Green "CHANGELOG.md generated ($($raw.Count) commit(s) processed)."
}

# ==============================================================================
# TASK: Publish
# Builds manifest validation, packages the module, and stages deployment files.
# STRICT dependency: Package (which itself depends on Test -> Lint).
# ==============================================================================
task Publish Package, Changelog, {
    # Validate the manifest is well-formed before any deployment.
    $manifest = Test-ModuleManifest -Path $ManifestPath -ErrorAction Stop
    Write-Build Cyan "Manifest valid: $($manifest.Name) v$($manifest.Version)"

    $deployDir = Join-Path $ArtifactDir 'deploy'
    if (Test-Path $deployDir) { Remove-Item $deployDir -Recurse -Force }
    New-Item -ItemType Directory -Path $deployDir -Force | Out-Null

    # Stage the packaged zip + changelog + legal files for release consumption.
    Copy-Item -Path (Join-Path $ArtifactDir "EscapeFromCorporate-$($manifest.Version).zip") `
        -Destination $deployDir -Force
    foreach ($doc in 'CHANGELOG.md', 'README.md', 'LICENSE', 'NOTICE') {
        $src = Join-Path $ProjectRoot $doc
        if (Test-Path $src) { Copy-Item $src -Destination $deployDir -Force }
    }

    # Emit a deployment metadata descriptor for downstream automation.
    [pscustomobject]@{
        module    = $manifest.Name
        version   = $manifest.Version.ToString()
        stagedUtc = [datetime]::UtcNow.ToString('o')
        artifacts = (Get-ChildItem $deployDir).Name
    } | ConvertTo-Json -Depth 4 |
        Set-Content -Path (Join-Path $deployDir 'deploy-manifest.json') -Encoding UTF8

    Write-Build Green "Publish staging complete: $deployDir"
}

# ==============================================================================
# TASK: Clean
# Removes build artifacts (does NOT touch vendored modules by default).
# ==============================================================================
task Clean {
    if (Test-Path $ArtifactDir) {
        Remove-Item $ArtifactDir -Recurse -Force
        Write-Build Green "Removed artifacts directory."
    }
    else {
        Write-Build DarkGray "Nothing to clean."
    }
}

# ==============================================================================
# TASK: Docs
# Generates/updates platyPS markdown from the loaded module CBH and compiles the
# external MAML help (en-US/EscapeFromCorporate-help.xml). Depends on Bootstrap
# so platyPS is vendored locally.
# ==============================================================================
task Docs Bootstrap, {
    Import-Module platyPS -MinimumVersion '0.14.2' -Force

    $helpMarkdownDir = Join-Path $ProjectRoot 'docs\help'
    $helpLocaleDir   = Join-Path $SourceRoot 'en-US'

    if (-not (Test-Path $helpMarkdownDir)) {
        New-Item -ItemType Directory -Path $helpMarkdownDir -Force | Out-Null
    }
    if (-not (Test-Path $helpLocaleDir)) {
        New-Item -ItemType Directory -Path $helpLocaleDir -Force | Out-Null
    }

    # Import the module fresh so platyPS reads current CBH/parameter metadata.
    Import-Module $ManifestPath -Force

    # If markdown does not exist yet, generate it from the module; otherwise sync
    # it so parameter changes are reflected without clobbering hand-edited prose.
    $existing = Get-ChildItem -Path $helpMarkdownDir -Filter '*.md' -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Build Cyan 'Generating initial platyPS markdown from module CBH.'
        New-MarkdownHelp -Module 'EscapeFromCorporate' `
            -OutputFolder $helpMarkdownDir `
            -WithModulePage `
            -HelpVersion '1.0.0' `
            -Locale 'en-US' `
            -Force | Out-Null
    }
    else {
        Write-Build Cyan 'Syncing existing markdown with current module metadata.'
        Update-MarkdownHelp -Path $helpMarkdownDir | Out-Null
    }

    # Compile markdown -> MAML external help XML into the module's en-US folder.
    Write-Build Cyan "Compiling MAML into: $helpLocaleDir"
    New-ExternalHelp -Path $helpMarkdownDir `
        -OutputPath $helpLocaleDir `
        -Force | Out-Null

    $maml = Join-Path $helpLocaleDir 'EscapeFromCorporate-help.xml'
    if (-not (Test-Path $maml)) {
        throw "MAML generation failed: $maml was not produced."
    }
    Write-Build Green "External MAML help generated: $maml"
}

# ==============================================================================
# DEFAULT: full local pipeline
# ==============================================================================
task . Bootstrap, Lint, Test, Package