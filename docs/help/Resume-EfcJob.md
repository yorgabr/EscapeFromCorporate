---
external help file: EscapeFromCorporate-help.xml
Module Name: EscapeFromCorporate
online version: https://github.com/yorgabr/escape-from-corporate
schema: 2.0.0
---

# Resume-EfcJob

## SYNOPSIS
Resumes an interrupted efc job from its persisted state.

## SYNTAX

```
Resume-EfcJob [[-StateRoot] <String>] [<CommonParameters>]
```

## DESCRIPTION
Convenience wrapper that reads the persisted state and re-invokes Invoke-EfcJob using the stored source/destination signatures, continuing from the last checkpoint offset. Fails if no resumable state exists. If the matching job is already completed, it reports so and returns the state without further work.

## EXAMPLES

### Example 1: Resume the most recent interrupted transfer
```
Resume-EfcJob
```

Reads the persisted state and continues the transfer from the last checkpoint.

### Example 2: Resume a job stored in a custom state location
```
Resume-EfcJob -StateRoot 'D:\efc-state'
```

Resumes using a non-default state directory (useful for isolated or test setups).

## PARAMETERS

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

### None

## OUTPUTS

### System.Management.Automation.PSCustomObject
The final job state after resumption.

## NOTES
Author  : Yorga Babuscan <yorgabr@gmail.com>
License : Apache License 2.0

Throws when no persisted job state exists.

## RELATED LINKS

[Invoke-EfcJob]()
[Get-EfcJobState]()
[Clear-EfcState]()
