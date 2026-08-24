# Contributing to Escape From Corporate

Welcome. This guide is written for contributors new to PowerShell module development — take it step by step; you don't need prior Invoke-Build or Pester experience.

## Prerequisites

You'll need Windows 10 or 11 with **Windows PowerShell 5.1** (not just PowerShell 7) and Git. No administrator rights are required anywhere in this workflow — everything installs in user scope.

## First-Time Setup

```powershell
git clone https://github.com/yorgabr/escape-from-corporate.git
cd escape-from-corporate

# Bootstrap dev dependencies locally (Pester, PSScriptAnalyzer, Invoke-Build, platyPS).
# This downloads into .\modules\ only — nothing global, no admin.
.\tools\Install-BuildDependencies.ps1
```

## The Development Loop

We use `Invoke-Build`. Every task is defined in `efc.build.ps1`, at the project root, so Invoke-Build discovers it automatically — no `-File` argument needed.

```powershell
Import-Module InvokeBuild

Invoke-Build Lint     # static analysis
Invoke-Build Test     # runs Lint, then Pester
Invoke-Build .        # full pipeline
```

**Rule of thumb:** if `Test` passes locally, CI will pass too. The GitHub Actions workflow calls the exact same tasks.

## Project Layout (Where Things Live)

| Folder | What goes here |
|--------|----------------|
| `src/EscapeFromCorporate/Public/` | User-facing cmdlets (exported). One function per file. |
| `src/EscapeFromCorporate/Private/` | Internal engine. Grouped by domain: `Engine`, `Log`, `State`, `UI`, `Validation`. |
| `tests/Unit/` | Fast, isolated tests. Mock everything external. |
| `tests/Integration/` | End-to-end orchestration tests (still fully mocked — no real copies). |
| `tools/` | The dependency bootstrapper (`Install-BuildDependencies.ps1`). |
| `docs/` | Architecture reference and the usage guide. |

`efc.build.ps1` itself — the Invoke-Build pipeline definition — lives at the project root, not in a `build/` subfolder.

## Coding Standards

- **Language:** 100% English — code, comments, variables, docstrings, log messages.
- **One function per file**, named exactly as the file (e.g. `Get-EfcState.ps1`).
- **Comment-Based Help (CBH)** is mandatory on every **public** function: include
  `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, and at least one `.EXAMPLE`.
- **`Set-StrictMode -Version Latest`** at the top of every function body.
- **No emojis** anywhere in the codebase.
- **Approved verbs only** (`Get-Verb`). Use `Invoke`, `Get`, `Write`, `Read`, etc.

One rule worth calling out on its own: under `Set-StrictMode -Version Latest`, reading a `$script:` variable that was never assigned throws — even inside `if (-not $var)`. If a function needs a lazily-initialized script-scoped cache (a compiled regex, a P/Invoke registration flag, a spinner frame index), declare and assign it eagerly at the top of the file, outside any function body, so the lazy-init check itself never touches an unset variable.

## Writing Tests

We use **Pester 5** syntax (not the legacy 3.x style).

```powershell
Describe 'Get-EfcSignature' {
    BeforeAll {
        Import-Module .\src\EscapeFromCorporate\EscapeFromCorporate.psd1 -Force
    }

    It 'normalizes equivalent paths to the same hash' {
        $a = Get-EfcSignature -Path 'C:\Data\'
        $b = Get-EfcSignature -Path 'c:\data'
        $a.Hash | Should -Be $b.Hash
    }
}
```

Key rules:
- Use `$TestDrive` for temporary files — Pester auto-cleans it.
- To test **private** functions, wrap assertions in `InModuleScope EscapeFromCorporate { }`. This isn't optional style: private functions aren't exported, so calling them directly from test scope fails with `CommandNotFoundException` the moment the module actually imports cleanly.
- **Never** execute a real `robocopy` transfer. Inject a fake via the `-ProcessFactory`
  or `-RobocopyRunner` parameters, or `Mock` the wrapper function.

### Testing the pause/resume engine

`Suspend-EfcProcess` calls the real `Get-Process -Id`, so when testing `Watch-RobocopyProcess` you MUST `Mock Suspend-EfcProcess` — never rely on a fake process object exposing a `.Handle`. To test `Suspend-EfcProcess` itself, spawn a real short-lived process (`Start-Process cmd.exe`) and always clean it up in a `finally` block. The function is contractually fail-safe: it returns `[bool]` and never throws, so assert on the return type when an EDR might block ntdll.

## Commit Messages (Conventional Commits)

The `Changelog` task parses these automatically. Format:

```
<type>(<optional scope>): <description>
```

Allowed types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`.

Examples:

```
feat(engine): add restartable mode flag
fix(log): correct byte offset drift on multibyte paths
docs(readme): document DryRun usage
```

Add a `!` after the type for breaking changes: `feat(cli)!: rename Source parameter`.

## Pull Request Checklist

- [ ] `Invoke-Build Test` passes locally.
- [ ] New/changed public functions have complete CBH with examples.
- [ ] Tests added for new behavior. Pester reports coverage against its default 75% target (see `artifacts\coverage.xml`); the build doesn't hard-fail below it, but a drop is worth a second look.
- [ ] Commit messages follow Conventional Commits.
- [ ] No global installs, no admin requirements introduced.

## Questions

Open an issue with the `question` label. Welcome aboard.