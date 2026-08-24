---
external help file: EscapeFromCorporate-help.xml
Module Name: EscapeFromCorporate
online version: https://github.com/yorgabr/escape-from-corporate
schema: 2.0.0
---

# Clear-EfcState

## SYNOPSIS
Removes the persisted efc job state (and optionally its logs).

## SYNTAX

```
Clear-EfcState [[-StateRoot] <String>] [-IncludeLogs] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Deletes state.json and its sidecar files (.tmp, .bak). With -IncludeLogs, also purges the logs directory. Supports -WhatIf and -Confirm via ShouldProcess with High confirm impact. Use before starting an unrelated job or to reclaim space after a validated, deleted transfer.

## EXAMPLES

### Example 1: Remove the current state (with confirmation)
```
Clear-EfcState
```

Removes the current state file after confirmation (ConfirmImpact is High).

### Example 2: Purge state and logs without prompting
```
Clear-EfcState -IncludeLogs -Confirm:$false
```

Removes state and the logs directory without prompting.

### Example 3: Preview what would be removed
```
Clear-EfcState -IncludeLogs -WhatIf
```

Shows which files would be removed without deleting anything.

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

### -IncludeLogs
Also remove the logs subdirectory under the state root.

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

### -StateRoot
Override for the state directory. Defaults to $env:LOCALAPPDATA\EscapeFromCorporate.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 0
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

## OUTPUTS

### None

## NOTES
Author  : Yorga Babuscan <yorgabr@gmail.com>
License : Apache License 2.0

## RELATED LINKS

[Invoke-EfcJob]()
[Get-EfcJobState]()
[Resume-EfcJob]()
