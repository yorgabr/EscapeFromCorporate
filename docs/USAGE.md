# Escape From Corporate - Usage Guide

Scenario-driven guide for operating `efc` in the field. For the command reference,
use `Get-Help Invoke-EfcJob -Full`. For internal design, see
[ARCHITECTURE.md](ARCHITECTURE.md).

## Table of Contents

1. [Before You Start](#1-before-you-start)
2. [The Golden Path (Typical Workflow)](#2-the-golden-path-typical-workflow)
3. [Scenario: Sizing a Transfer with DryRun](#3-scenario-sizing-a-transfer-with-dryrun)
4. [Scenario: Recovering from a Network Drop](#4-scenario-recovering-from-a-network-drop)
5. [Scenario: Pausing to Free Bandwidth](#5-scenario-pausing-to-free-bandwidth)
6. [Scenario: Aborting Safely](#6-scenario-aborting-safely)
7. [Scenario: High-Assurance Validation with Sampled Hashing](#7-scenario-high-assurance-validation-with-sampled-hashing)
8. [Scenario: Starting Over with -Force](#8-scenario-starting-over-with--force)
9. [Understanding the Safe-to-Delete Gate](#9-understanding-the-safe-to-delete-gate)
10. [Reading the Live Progress Display](#10-reading-the-live-progress-display)
11. [Robocopy Exit Codes](#11-robocopy-exit-codes)
12. [Troubleshooting](#12-troubleshooting)
13. [Frequently Asked Questions](#13-frequently-asked-questions)

---

## 1. Before You Start

`efc` is built for a specific situation: a locked-down corporate Windows laptop with
no admin rights, moving large volumes of files to a home NAS over the local network.

You'll need Windows PowerShell 5.1 (built into Windows 10/11), network access to your
destination (a UNC share such as `\\HOME-NAS\Backup`), and enough free space at the
destination for the full source tree.

**Import the module:**

```powershell
Import-Module .\src\EscapeFromCorporate\EscapeFromCorporate.psd1
```

**Verify it loaded and read the help:**

```powershell
Get-Command -Module EscapeFromCorporate
Get-Help Invoke-EfcJob -Full
```

You can call the primary command as `Invoke-EfcJob`, or via the aliases `efc`,
`Invoke-Efc`, or `Escape-FromCorporate`.

---

## 2. The Golden Path (Typical Workflow)

The recommended end-to-end flow for a first-time transfer:

**Step 1 - Size it first (no data moved):**

```powershell
efc -Source 'C:\Users\me\CorporateData' -Destination '\\HOME-NAS\Backup\Dump' -DryRun
```

This prints the projected file count and total bytes so you can confirm the
destination has room and estimate how long it will take.

**Step 2 - Run the transfer:**

```powershell
efc -Source 'C:\Users\me\CorporateData' -Destination '\\HOME-NAS\Backup\Dump'
```

A live display appears: a spinner, percentage, throughput, file counters, and ETA.
The control hint reminds you of the runtime keys:

```
Transfer running. Controls: [P]ause  [R]esume  [A]bort
```

**Step 3 - Let it finish and read the verdict:**

When robocopy completes, `efc` runs a post-copy integrity check automatically and
prints a summary. If everything matched, you will see:

```
 VALIDATION PASSED - Source files are SAFE TO DELETE.
 Verify the destination before removing anything.
```

**Step 4 - Verify, then (optionally) reclaim space:**

Spot-check the destination yourself. Once satisfied, you may delete the source and
clean up efc's state and logs:

```powershell
Clear-EfcState -IncludeLogs
```

> **Important:** `efc` never deletes your source files. It only tells you when it is
> safe to do so. The deletion is always your explicit, manual action.

---

## 3. Scenario: Sizing a Transfer with DryRun

**Goal:** Know the workload before committing.

`-DryRun` runs a list-only enumeration (`robocopy /L`) - it reads the source but
copies nothing.

```powershell
efc -Source 'C:\Data' -Destination '\\NAS\Dump' -DryRun
```

Sample output:

```
DryRun projection (no data copied):
  Files : 284,531
  Bytes : 32,212,254,720 (30.00 GB)
  Dirs  : 1,204
```

Use it to confirm the destination has enough free space, estimate duration by
dividing total bytes by your typical LAN throughput, and sanity-check that you
pointed at the right source folder before committing to a long run.

DryRun is safe to run repeatedly and never touches state.json.

---

## 4. Scenario: Recovering from a Network Drop

**The situation:** You are 60% through a 30 GB transfer to the NAS and the Wi-Fi
drops, or you close the laptop lid, or PowerShell is killed.

**What efc did automatically:** Throughout the run, efc checkpointed its progress to
`state.json` every 15 seconds, recording the exact byte offset in the robocopy log
up to which files were counted.

**How to recover - just run the same command again:**

```powershell
efc -Source 'C:\Data' -Destination '\\NAS\Dump'
```

efc detects the matching interrupted job and resumes:

```
Resuming interrupted job (offset 21943040).
```

**Or use the explicit resume command** (reads source/destination from the saved
state, so you do not have to retype them):

```powershell
Resume-EfcJob
```

**Why this is safe and fast:** robocopy is a differential engine. On resume, it skips
every file that already exists identically at the destination (same size and
timestamp) and copies only what remains. You will see the progress bar advance
quickly at first as robocopy re-scans and skips completed files - this is expected,
not a glitch.

**If the log pointer was corrupted** (rare - e.g. the log file was truncated), efc
falls back to a differential restart and tells you:

```
Note: resuming via robocopy differential. Progress may jump as identical files are skipped.
```

The outcome is identical; only the internal bookkeeping differs.

---

## 5. Scenario: Pausing to Free Bandwidth

**The situation:** A large transfer is saturating your home network and you need
bandwidth for a video call.

**Press `P`** at any time during the transfer. efc suspends the robocopy process:

```
Paused (process suspended). Press [R] to resume.
```

While paused, robocopy consumes no CPU, disk, or network - the transfer is truly
frozen, not just hidden.

**Press `R`** to resume when you are done:

```
Resumed.
```

> **Corporate EDR note:** Some corporate security agents block the low-level process
> suspension API. If that happens, efc automatically falls back to a "soft pause": it
> stops updating the display, but robocopy keeps running in the background. You will
> see `Paused (soft-pause)` instead. This is a graceful degradation - your transfer is
> never at risk, and resuming works the same way. When you resume, the progress may
> jump forward to catch up on what completed during the soft pause.

---

## 6. Scenario: Aborting Safely

**The situation:** You started the wrong transfer, or you simply need to stop.

**Press `A`.** efc stops the robocopy process cleanly and saves state:

```
Abort requested. Stopping transfer...

 Job aborted. State saved; re-run to resume.
```

Aborting is safe: the partial copy at the destination is intact, and the state is
preserved. You can resume later with the same command or `Resume-EfcJob`, or discard
everything and start fresh with `-Force`.

Aborting does **not** delete anything - not the source, not the partial destination.

---

## 7. Scenario: High-Assurance Validation with Sampled Hashing

**The situation:** The data is critical (legal, financial, medical) and size-plus-
timestamp matching is not enough assurance for you.

By default, efc validates using robocopy's differential list pass - a fast, reliable
check that every source file now exists identically at the destination. For deeper
assurance, request **content-level SHA256 verification of a random sample** of files
via `-SampleHashCount`:

```powershell
efc -Source 'C:\Legal\Case' -Destination '\\NAS\Vault' -SampleHashCount 200
```

**What sampled hashing does:** After the copy, efc picks the requested number of random
source files, computes their SHA256 hashes, and compares them byte-for-byte against the
corresponding destination files. Any mismatch (or missing destination file) fails
validation and blocks the safe-to-delete signal.

**Why sample instead of hashing everything:** Hashing every file in a tens-of-GB tree
would take as long as the copy itself. Sampling gives strong statistical confidence at
a fraction of the cost. Choose a sample size proportional to your risk tolerance -
larger samples for more critical data (the maximum is 10,000 files per run).

**Interpreting the result:** The summary reports the method
(`RobocopyList+SampledSHA256`) and the combined mismatch count. The final state records
`validation.sampleHashCount`, `validation.hashSamplesChecked`, and
`validation.hashMismatches` for audit purposes. Zero mismatches from both the list pass
and the hash sample is the only condition that flips `safeToDeleteSource` to true.

**Inspecting the audit trail afterward:**

```powershell
Get-EfcJobState | Select-Object -ExpandProperty validation
```
---

## 8. Scenario: Starting Over with -Force

**The situation:** You want to discard a previous job entirely and start clean - for
example, the previous destination was wrong, or the state is confusing you.

```powershell
efc -Source 'C:\Data' -Destination '\\NAS\Dump' -Force
```

`-Force` discards any existing state for this source/destination pair and begins a
fresh transfer. It does **not** delete files already at the destination; robocopy will
simply re-evaluate them and skip identical ones.

**When you will be told to use -Force:** If you try to run a job whose source or
destination differs from the one already saved in state, efc refuses and protects the
existing job:

```
Existing state targets a different source/destination pair
(key 'a94a8fe5-0beec7b5' vs '1d7c5b8a-3e46f8a1'). Use -Force to override.
```

This guard prevents you from accidentally clobbering an in-progress job by pointing at
a different folder. If you genuinely want to switch jobs, add `-Force` (or clear the
old state first with `Clear-EfcState`).

---

## 9. Understanding the Safe-to-Delete Gate

This is the most important concept in efc. The `safeToDeleteSource` signal is the only
thing that authorizes you to delete your source data, and it defaults to **false**.

It flips to **true** only when **all** of the following hold:

1. Robocopy exited with a success code (below 8).
2. The post-copy differential list pass reports **zero** pending files.
3. If sampled hashing was requested, **zero** hash mismatches.

If any check fails, you will see one of:

```
 VALIDATION FAILED - 3 mismatch(es). Do NOT delete the source.
```

or

```
 Escape From Corporate - Job Failed
 ...
```

**Rule of thumb:** If you did not see the green "SAFE TO DELETE" message, treat the
source as not yet safely copied. Re-run the command to let robocopy complete the
remaining or mismatched files, then let validation run again.

Even when efc says it is safe, **spot-check the destination yourself** before deleting.
efc is a careful assistant, not a substitute for your judgment on irreplaceable data.

---

## 10. Reading the Live Progress Display

During a transfer you will see a single status line updating in place:

```
/  30.0% | 9.00 GB/30.00 GB | 40.00 MB/s | files 84,210/284,531 | ETA 00:08:57
```

| Segment | Meaning |
|---------|---------|
| `/` | Spinner frame - confirms efc is actively polling (rotates: `| / - \`) |
| `30.0%` | Percentage of total bytes copied |
| `9.00 GB/30.00 GB` | Bytes copied / total bytes expected |
| `40.00 MB/s` | Current average throughput |
| `files 84,210/284,531` | Files copied / total files expected |
| `ETA 00:08:57` | Estimated time remaining (hh:mm:ss) |

When paused, the spinner is replaced by `[||]`.

**On non-interactive hosts** (CI, redirected output, the ISE), the in-place display
degrades gracefully to a periodic linear line printed every few seconds, so logs
remain readable without cursor tricks.

---

## 11. Robocopy Exit Codes

efc interprets robocopy's exit code to decide whether to validate. Robocopy uses a
bitmask where higher values indicate more serious conditions:

| Exit code | Meaning | efc treatment |
|-----------|---------|---------------|
| 0 | No files copied; source and destination already in sync | Success |
| 1 | Files copied successfully | Success |
| 2 | Extra files/dirs detected at destination | Success |
| 3 | Files copied + extras present | Success |
| 5, 6, 7 | Combinations of copied/mismatched/extra | Success (validated) |
| **8 and above** | At least one failure (access denied, path error, etc.) | Failed - no validation |

Any code **below 8** is treated as a successful robocopy run, after which efc proceeds
to integrity validation. Codes **8 or higher** mark the job as `Failed`, and the
safe-to-delete gate stays closed.

The exact exit code is shown in the final summary and stored in `state.json` under
`robocopy.exitCode` for diagnostics.

---

## 12. Troubleshooting

### "Pre-flight validation failed"

**Cause:** The source does not exist, is not a directory, or the destination server is
unreachable.

**Fix:**
- Confirm the source path exists: `Test-Path 'C:\Data'`.
- Confirm the NAS is online and the share is reachable: `Test-Path '\\HOME-NAS\Backup'`.
- If on VPN, ensure the tunnel is up before running efc.

### "Use -Force to override" (Conflict)

**Cause:** A saved job targets a different source/destination than the one you just
specified.

**Fix:** Either resume the original job by matching its paths, or intentionally switch
by adding `-Force`, or clear the old job with `Clear-EfcState`.

### Progress "jumps" forward on resume

**Cause:** This is expected. On resume, robocopy re-scans and skips files that already
exist identically, so the counter races ahead until it reaches the point of
interruption.

**Fix:** None needed - this is correct differential behavior.

### Pause shows "soft-pause" instead of "process suspended"

**Cause:** A corporate security agent (EDR) blocked the low-level suspension API.

**Fix:** None required. The transfer continues correctly in the background; resume
works normally. If you must hard-pause, the only workaround is environment-dependent
and typically outside your control on a locked-down machine.

### The transfer is slow

**Causes and levers:**
- **Network is the bottleneck.** LAN throughput caps your speed; efc adds negligible
  overhead. Check your NAS and switch link speeds.
- **Many tiny files.** Hundreds of thousands of small files are inherently slower than
  a few large ones due to per-file overhead. This is a robocopy/filesystem reality.
- **Restartable mode (`/Z`) adds overhead.** If you enabled `-Restartable` on a stable
  link, consider dropping it - it trades speed for resilience.

### Validation failed after what looked like a complete copy

**Cause:** Some files could not be copied (locked, permission-denied) or changed during
the copy.

**Fix:** Re-run the same command. Robocopy retries and copies the outstanding files;
validation runs again. Check `state.json` `metrics.filesFailed` and the robocopy log
under the state's `logs` folder for the specific paths.

### I lost track of a running job

**Fix:** Inspect the saved state at any time:

```powershell
Get-EfcJobState | Select-Object status, @{n='pct';e={$_.metrics.percentComplete}}
```

---

## 13. Frequently Asked Questions

**Does efc ever delete my source files?**
No. efc only signals when a copy is validated and safe to delete. Deletion is always
your manual action.

**Where is the state stored?**
In `%LOCALAPPDATA%\EscapeFromCorporate\state.json`, with robocopy logs under the `logs`
subfolder. Override with `-StateRoot` if needed.

**Can I run two different transfers at once?**
efc tracks a single active job in its default state slot. To run genuinely independent
jobs, give each a separate `-StateRoot` directory.

**Does it work to a local drive, not just a NAS?**
Yes. Any destination robocopy accepts works - local drives, external USB, and UNC
shares alike.

**Do I need administrator rights?**
No. efc runs entirely in user space. The only privileged-looking operation - process
suspension for pause - uses an API available for your own processes without elevation,
and degrades gracefully if blocked.

**Can I resume on a different day?**
Yes. State persists on disk. As long as the source and destination paths are the same,
running the command (or `Resume-EfcJob`) picks up where you left off.

**What if the destination already has some of the files?**
robocopy skips identical files and copies only what differs or is missing. This is why
`-Force` is safe: it re-evaluates the destination rather than blindly recopying.

**How accurate is the ETA?**
The ETA is a running estimate based on average throughput so far. It stabilizes as the
transfer progresses and can swing early on or when file sizes vary widely.

---

For deeper technical detail, see [ARCHITECTURE.md](ARCHITECTURE.md). For contributing,
see [CONTRIBUTING.md](../CONTRIBUTING.md).