#Requires -Version 5.1
<#
.SYNOPSIS
    Resolves the filesystem root (drive or UNC share) of a path.

.DESCRIPTION
    Returns the drive root ('C:\') for local paths or the share root
    ('\\server\share') for UNC paths, without requiring the path itself to
    exist. Used by preflight checks to validate reachability of the true root
    that must already exist - robocopy can create arbitrarily deep
    subdirectories beneath a reachable root, so only the root itself needs to
    be verified, not the immediate parent folder (which may legitimately not
    exist yet for a brand-new, multi-level destination path).

.PARAMETER Path
    The path (local or UNC) to resolve the root of.

.OUTPUTS
    [string] the root path, or $null if it cannot be determined.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Get-EfcPathRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest

    if ($Path -match '^\\\\[^\\]+\\[^\\]+') {
        return $Matches[0]
    }

    $qualifier = Split-Path -Path $Path -Qualifier -ErrorAction SilentlyContinue
    if ($qualifier) {
        return "$qualifier\"
    }

    return $null
}