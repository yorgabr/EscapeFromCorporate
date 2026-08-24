# Escape From Corporate (efc)

<!-- BANNER PLACEHOLDER: docs/assets/banner.png -->
![Escape From Corporate](docs/assets/banner-placeholder.png)

[![CI](https://github.com/yorgabr/escape-from-corporate/actions/workflows/ci.yml/badge.svg)](https://github.com/yorgabr/escape-from-corporate/actions/workflows/ci.yml)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE.svg)](https://learn.microsoft.com/powershell/)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Coverage target](https://img.shields.io/badge/coverage_target-75%25-brightgreen.svg)](#testing)

> Secure, resumable file dump utility for locked-down corporate Windows environments.
> No admin rights. No third-party tools. Just native PowerShell 5.1 and robocopy.

## The Problem

Corporate laptops are locked down: no Rsync, no Rclone, no module installs, no admin. Yet you need to move tens of gigabytes and hundreds of thousands of files to a home NAS reliably, resumably, and with proof that the copy is exact before deleting anything. `efc` wraps `robocopy.exe` with an asynchronous, non-blocking control layer that turns that gap into a solved problem, without asking for anything the environment won't grant.

## What it does

Everything runs entirely in user space. Dependencies are vendored locally rather than installed globally, and the one operation that sounds like it needs elevation — suspending the robocopy process for pause — uses an ntdll API that works for processes you own without admin rights, degrading gracefully to a soft pause when a corporate EDR agent blocks it.

Transfers are resumable and idempotent: an interrupted job picks up from the exact byte offset in the robocopy log where it left off, so recovering a 30 GB transfer after a dropped VPN connection costs seconds, not a restart from zero. While a transfer runs, you get a live status line — spinner, percentage, throughput, file counters, ETA — and can pause, resume, or abort at any moment with a single keystroke. Before you're told it's safe to delete anything, `efc` runs a differential validation pass against the destination, optionally backed by sampled SHA256 hashing for legal, financial, or otherwise irreplaceable data. And if you just want to know how big a transfer is before committing to it, `-DryRun` projects the file count and total bytes with zero data movement.

## Requirements

`efc` needs only Windows 10 or 11 with Windows PowerShell 5.1 (built in — this is not PowerShell 7) and `robocopy.exe`, which ships with Windows. No administrator rights are required, either to run `efc` or to build and test it; the handful of build/test dependencies (Pester, PSScriptAnalyzer, Invoke-Build, platyPS) are vendored locally into `.\modules\` on first run — see [Building](#building).

## Installation

```powershell
# Clone and import (no gallery publish required)
git clone https://github.com/yorgabr/escape-from-corporate.git
Import-Module .\escape-from-corporate\src\EscapeFromCorporate\EscapeFromCorporate.psd1
```

## Usage

```powershell
# Basic transfer to a NAS share
Invoke-EfcJob -Source 'C:\Users\me\Data' -Destination '\\HOME-NAS\Backup\Dump'

# Project the workload first (no copy)
efc -Source 'C:\Data' -Destination '\\NAS\Dump' -DryRun

# Force a clean restart, ignoring prior state
efc -Source 'C:\Data' -Destination '\\NAS\Dump' -Force

# Restartable mode for large files over flaky links
efc -Source 'C:\Data' -Destination '\\NAS\Dump' -Restartable

# Inspect / resume / clean up
Get-EfcJobState
Resume-EfcJob
Clear-EfcState -IncludeLogs
```

At runtime: press **P** to pause, **R** to resume, **A** to abort.

For scenario-by-scenario walkthroughs — sizing a transfer, recovering from a dropped network, sampled-hash validation, troubleshooting, FAQ — see [docs/USAGE.md](docs/USAGE.md). For the full command reference, run `Get-Help Invoke-EfcJob -Full`.

## Architecture

```
Invoke-EfcJob (Public controller)
   |
   +-- Test-EfcPreflight        -> feasibility + DryRun projection (robocopy /L)
   +-- Resolve-EfcResumption    -> idempotent decision (Resume/Force/Conflict)
   +-- Connect-Robocopy         -> background process (no pipe deadlock, /LOG file)
   +-- Watch-RobocopyProcess    -> non-blocking loop:
   |       Read-RobocopyLog       (delta read via FileStream, byte-accurate offset)
   |       Write-EfcSpinner       (in-place UI frame)
   |       Read-EfcKeyCommand     (KeyAvailable poll -> Pause/Resume/Abort)
   |       Suspend-EfcProcess     (ntdll suspend, soft-pause fallback)
   |       Write-EfcState         (throttled atomic checkpoint)
   +-- Test-EfcCopyIntegrity    -> differential validation -> safeToDeleteSource
```

State persists to `%LOCALAPPDATA%\EscapeFromCorporate\state.json` using the **Log Pointer Offset** strategy for exact resumption. The full design rationale — sequence diagrams, the state machine, the failure-mode table — lives in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Testing

```powershell
Invoke-Build Test
```

`Test` depends on `Lint` (PSScriptAnalyzer), which in turn depends on `Bootstrap`, so a single invocation vendors Pester, PSScriptAnalyzer, Invoke-Build, and platyPS into `.\modules\`, lints the source, and runs the full Pester suite — all without touching a real file. Code coverage is measured against Pester's default 75% target and written to `artifacts\coverage.xml` in JaCoCo format for CI ingestion; no multi-gigabyte transfer, real or fake, is ever executed by a test.

## Building

```powershell
Invoke-Build .          # full pipeline: Bootstrap -> Lint -> Test -> Package
Invoke-Build Publish    # staged release artifacts (zip + changelog + legal files)
```

`efc.build.ps1` lives at the project root, so no `-File` argument is needed when run from there — Invoke-Build finds it automatically.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Author

Yorga Babuscan <yorgabr@gmail.com>