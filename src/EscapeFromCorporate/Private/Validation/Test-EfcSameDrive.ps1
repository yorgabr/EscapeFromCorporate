#Requires -Version 5.1
<#
.SYNOPSIS
    Tells whether source and destination live on the same drive (or network share).

.DESCRIPTION
    Both paths are first resolved through aliases (subst, mapped drives, junctions,
    symlinks) and then reduced to a drive/share key. Same key = same drive.

    Only EXPLICIT matches are reported as "same": when a key cannot be determined,
    the answer is Same = $false (Relation 'Unknown'); other preflight guards deal
    with such paths. Different shares of the same server are different keys.

.PARAMETER PathResolver
    Optional resolver: { param($Path) <resolved path string> }. Defaults to
    Resolve-EfcFinalPath. Injectable so the decision logic is testable anywhere.

.PARAMETER LocalNames
    Passed to ConvertTo-EfcDriveKey. Injectable for tests.

.OUTPUTS
    PSCustomObject: Same, Relation (SameDrive|DifferentDrive|Unknown), SourceKey,
    DestinationKey, SourceFinal, DestinationFinal, SourceAliased, DestinationAliased.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Test-EfcSameDrive {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourcePath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DestinationPath,
        [scriptblock] $PathResolver,
        [string[]] $LocalNames
    )

    Set-StrictMode -Version Latest

    if (-not $PathResolver) {
        $PathResolver = { param($p) (Resolve-EfcFinalPath -Path $p).Path }
    }

    $keyArgs = @{}
    if ($PSBoundParameters.ContainsKey('LocalNames')) { $keyArgs['LocalNames'] = $LocalNames }

    $resolve = {
        param($original)
        $r = $null
        try { $r = & $PathResolver $original } catch { $r = $null }
        if ([string]::IsNullOrWhiteSpace([string]$r)) { $r = $original }
        return (ConvertTo-EfcPlainPath -Path ([string]$r))
    }

    $srcFinal = & $resolve $SourcePath
    $dstFinal = & $resolve $DestinationPath

    $srcKey = ConvertTo-EfcDriveKey -Path $srcFinal @keyArgs
    $dstKey = ConvertTo-EfcDriveKey -Path $dstFinal @keyArgs

    $relation = 'Unknown'
    if ($srcKey -and $dstKey) {
        $relation = if ($srcKey -eq $dstKey) { 'SameDrive' } else { 'DifferentDrive' }
    }

    $srcIn = (ConvertTo-EfcPlainPath -Path $SourcePath).TrimEnd('\')
    $dstIn = (ConvertTo-EfcPlainPath -Path $DestinationPath).TrimEnd('\')

    return [pscustomobject]@{
        Same               = ($relation -eq 'SameDrive')
        Relation           = $relation
        SourceKey          = $srcKey
        DestinationKey     = $dstKey
        SourceFinal        = $srcFinal
        DestinationFinal   = $dstFinal
        SourceAliased      = ($srcFinal.TrimEnd('\') -ne $srcIn)
        DestinationAliased = ($dstFinal.TrimEnd('\') -ne $dstIn)
    }
}
