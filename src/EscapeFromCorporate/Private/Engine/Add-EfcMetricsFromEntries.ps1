#Requires -Version 5.1
<#
.SYNOPSIS
    Reconciles parsed log entries into the running job metrics.

.DESCRIPTION
    Single source of truth for translating parsed robocopy log entries (File/Dir/
    Error) into metric increments. Extracted to eliminate the triplicated switch
    that previously lived in the watch loop's consume, drain, and tail branches.

.PARAMETER State
    The live job state object (mutated in place).

.PARAMETER Entries
    Parsed entries produced by Read-RobocopyLog.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Add-EfcMetricsFromEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $State,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Entries
    )

    Set-StrictMode -Version Latest

    foreach ($entry in $Entries) {
        switch ($entry.Type) {
            'File' {
                $State.metrics.filesCopied++
                $State.metrics.bytesCopied += $entry.Size
            }
            'Dir'   { $State.metrics.dirsCreated++ }
            'Error' { $State.metrics.filesFailed++ }
        }
    }
}