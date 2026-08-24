#Requires -Version 5.1
<#
.SYNOPSIS
    Computes a deterministic signature for a source/destination path.

.DESCRIPTION
    Normalizes a path (unify separators, lowercase, trim trailing separator)
    and derives a stable SHA1 hash used to build the job's combinedKey for
    idempotent matching. The path need not exist yet (destination may be
    created by robocopy).

.OUTPUTS
    PSCustomObject: Path, NormalizedPath, Hash.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>
function Get-EfcSignature {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest

    # Unify forward slashes to backslashes BEFORE trimming/lowering. Without
    # this, 'C:/Data' and 'C:\Data' normalized to different strings ("c:/data"
    # vs "c:\data"), silently weakening both idempotent resume matching and
    # the source/destination self-collision guard in Test-EfcPreflight.
    $normalized = $Path.Trim().Replace('/', '\')
    $normalized = $normalized.TrimEnd('\').ToLowerInvariant()

    $sha1  = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
        $hash  = ($sha1.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    }
    finally {
        $sha1.Dispose()
    }

    return [pscustomobject]@{
        Path           = $Path.Trim()
        NormalizedPath = $normalized
        Hash           = $hash
    }
}