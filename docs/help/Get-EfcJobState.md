---
external help file: EscapeFromCorporate-help.xml
Module Name: EscapeFromCorporate
online version: https://github.com/yorgabr/escape-from-corporate
schema: 2.0.0
---

# Get-EfcJobState

## SYNOPSIS
Retrieves the current persisted efc job state for inspection.

## SYNTAX

```
Get-EfcJobState [[-StateRoot] <String>] [<CommonParameters>]
```

## DESCRIPTION
Reads state.json from the state directory and returns it as an object. Useful for checking the progress of an interrupted job before deciding whether to resume. Returns $null when no job exists.

## EXAMPLES

### Example 1: Inspect the current job
```
Get-EfcJobState
```

Returns the current job state object, or $null if no job exists.

### Example 2: Read completion percentage
```
(Get-EfcJobState).metrics.percentComplete
```

Inspects the completion percentage of the last known job.

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
The persisted state object, or $null when no state exists.

## NOTES
Author  : Yorga Babuscan <yorgabr@gmail.com>
License : Apache License 2.0

## RELATED LINKS

[Invoke-EfcJob]()
[Resume-EfcJob]()
[Clear-EfcState]()
