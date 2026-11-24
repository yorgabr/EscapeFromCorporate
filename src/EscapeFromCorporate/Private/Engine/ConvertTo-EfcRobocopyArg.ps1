#Requires -Version 5.1
<#
.SYNOPSIS
    Quotes a path for a robocopy command line without changing its meaning.

.DESCRIPTION
    Two Windows quirks are handled:
      * A trailing backslash before the closing quote ("C:\dir\") escapes the quote,
        so trailing separators are trimmed.
      * Trimming a ROOT turns 'C:\' into 'C:', which robocopy reads as "the current
        directory on drive C" - for a child started in System32 that is System32.
        Roots therefore become 'C:\.', which robocopy resolves to the drive root
        (verified on Windows PowerShell 5.1 with subst + a non-root current dir).

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function ConvertTo-EfcRobocopyArg {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path
    )

    Set-StrictMode -Version Latest

    $trimmed = $Path.TrimEnd('\')
    if ($trimmed -match '^[A-Za-z]:$') {
        $trimmed = $trimmed + '\.'
    }
    return ('"{0}"' -f $trimmed)
}
