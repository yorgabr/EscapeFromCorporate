#Requires -Version 5.1
<#
.SYNOPSIS
    Determines whether the current host supports interactive in-place UI rendering.

.DESCRIPTION
    Returns $false when output is redirected, when running under a non-console host,
    or when [Console]::KeyAvailable is unavailable. Callers use this to decide
    between in-place spinner rendering and linear log-style output.

.OUTPUTS
    [bool]

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Test-EfcInteractiveHost {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        if ([Console]::IsOutputRedirected) { return $false }
        if (-not $Host.UI.RawUI)           { return $false }
        # Probing KeyAvailable throws on hosts without a real console (e.g. some CI).
        $null = [Console]::KeyAvailable
        return $true
    }
    catch {
        return $false
    }
}
