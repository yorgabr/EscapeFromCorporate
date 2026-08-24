---
external help file: EscapeFromCorporate-help.xml
Module Name: EscapeFromCorporate
online version: https://github.com/yorgabr/escape-from-corporate
schema: 2.0.0
---

# Invoke-EfcJob

## SYNOPSIS
Securely copies a directory tree to a destination (local or UNC) with resumable, validated, progress-tracked transfers powered by robocopy.

## SYNTAX

```
Invoke-EfcJob [-Source] <String> [-Destination] <String> [-Force] [-DryRun] [-Restartable]
 [[-SampleHashCount] <Int32>] [[-StateRoot] <String>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Invoke-EfcJob is the primary controller for Escape From Corporate. It orchestrates the full lifecycle of a secure file dump:

1. Pre-flight validation and (optionally) a DryRun projection of pending work.
2. Idempotent resumption reconciliation against any persisted state.json.
3. Background robocopy spawn with file-based logging (no pipe deadlock).
4. A non-blocking watch loop rendering a live spinner, ETA, percentage, and throughput, while capturing P/R/A keystrokes for Pause/Resume/Abort.
5. Atomic checkpoint persistence to allow interrupted jobs to resume exactly.
6. Post-copy integrity validation and a clear "safe to delete" signal.

The utility is designed for locked-down corporate Windows 11 environments with no administrator privileges and no third-party sync tools; it relies solely on native PowerShell 5.1 and robocopy.exe.

## EXAMPLES

### Example 1: Basic transfer to a NAS share
```
Invoke-EfcJob -Source 'C:\Users\me\CorporateData' -Destination '\\HOME-NAS\Backup\Dump'
```

Starts (or resumes) a secure copy to the home NAS, rendering live progress and accepting P/R/A keystrokes at runtime.

### Example 2: Project the workload before copying
```
Invoke-EfcJob -Source 'C:\Data' -Destination 'D:\Backup' -DryRun
```

Projects how many files and bytes would be copied, without transferring anything.

### Example 3: Force a clean restart
```
Invoke-EfcJob -Source 'C:\Data' -Destination '\\NAS\Dump' -Force
```

Ignores any prior state and starts a completely fresh transfer.

### Example 4: Restartable mode over a flaky link (using the alias)
```
efc -Source 'C:\Data' -Destination '\\NAS\Dump' -Restartable
```

### Example 5: High-assurance transfer with sampled content verification
```
Invoke-EfcJob -Source 'C:\Legal\Case' -Destination '\\NAS\Vault' -SampleHashCount 200
```

After copying, verifies 200 randomly selected files by SHA256 at both source and
destination. Any content mismatch fails validation and blocks the safe-to-delete
signal.

Uses the 'efc' alias with restartable mode (robocopy /Z) for large files over an unreliable network.

## PARAMETERS

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

Required: False
Position: Nomeado
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Destination
Destination directory. Supports local paths and UNC shares (\\server\share\...).

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -DryRun
Enumerates the pending work via 'robocopy /L' without copying anything, printing the projected file count and total bytes. Useful for sizing and validation.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Nomeado
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -Force
Discards any existing job state for this source/destination pair and starts a clean transfer. Without -Force, a matching incomplete job is resumed.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Nomeado
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -Restartable
Enables robocopy restartable mode (/Z) for resilient resumption of large files over unreliable network links. Slightly slower but far more robust.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Nomeado
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -SampleHashCount
Number of files to sample for SHA256 content verification during the post-copy integrity check. 0 (default) uses robocopy differential list validation only. Higher values add content-level assurance at the cost of hashing that many random files at both the source and destination.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Nomeado
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -Source
Absolute path to the source directory to copy from.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 0
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -StateRoot
Overrides the state directory. Defaults to $env:LOCALAPPDATA\EscapeFromCorporate. Primarily an injection seam for testing.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Nomeado
Default value: $env:LOCALAPPDATA\EscapeFromCorporate
Accept pipeline input: False
Accept wildcard characters: False
```

### -WhatIf
Shows what would happen if the cmdlet runs. The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Nomeado
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

### None
Parameters are supplied explicitly.

## OUTPUTS

### System.Management.Automation.PSCustomObject
Summarizes the final job state (status, metrics, validation, safeToDeleteSource).

## NOTES
Author  : Yorga Babuscan <yorgabr@gmail.com>
License : Apache License 2.0

At runtime: press P to pause, R to resume, A to abort.

## RELATED LINKS

[Get-EfcJobState]()
[Resume-EfcJob]()
[Clear-EfcState]()
[Project home](https://github.com/yorgabr/escape-from-corporate)
