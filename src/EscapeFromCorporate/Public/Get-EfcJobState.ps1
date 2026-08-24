#Requires -Version 5.1
<#
.SYNOPSIS
    Retrieves the current persisted efc job state for inspection.

.DESCRIPTION
    Reads state.json from the state directory and returns it as an object. Useful for
    checking progress of an interrupted job before deciding whether to resume.

.PARAMETER StateRoot
    Override for the state directory. Defaults to $env:LOCALAPPDATA\EscapeFromCorporate.

.EXAMPLE
    Get-EfcJobState

    Returns the current job state, or $null if no job exists.

.EXAMPLE
    (Get-EfcJobState).metrics.percentComplete

    Inspects the completion percentage of the last known job.

.OUTPUTS
    PSCustomObject or $null.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Get-EfcJobState {
    <#
    .EXTERNALHELP EscapeFromCorporate-help.xml
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $StateRoot = (Join-Path $env:LOCALAPPDATA 'EscapeFromCorporate')
    )
    Set-StrictMode -Version Latest
    return Get-EfcState -StateRoot $StateRoot
}
