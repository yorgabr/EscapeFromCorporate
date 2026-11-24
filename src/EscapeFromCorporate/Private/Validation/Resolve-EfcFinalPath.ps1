#Requires -Version 5.1
<#
.SYNOPSIS
    Resolves subst drives, mapped drives, junctions and symlinks to the real path.

.DESCRIPTION
    Uses CreateFile (ZERO access rights) + GetFinalPathNameByHandle, which needs no
    elevation. When the path does not exist yet (a brand-new destination), the
    nearest existing ancestor is resolved and the missing tail is re-appended.

    Degrades gracefully: if the native call cannot be compiled/used (Constrained
    Language Mode, blocked P/Invoke) or fails, the plain full path is returned with
    Resolved = $false, so callers still get the textual drive comparison.

.OUTPUTS
    PSCustomObject: Path (plain, no \\?\ prefix), Resolved ([bool]).

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>

$script:EfcPathNativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Efc
{
    public static class PathNative
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa,
            uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr h);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(IntPtr h, StringBuilder sb, uint len, uint flags);

        private static readonly IntPtr Invalid = new IntPtr(-1);

        public static string FinalPath(string path, out int error)
        {
            error = 0;
            // access 0 | share READ+WRITE+DELETE | OPEN_EXISTING | BACKUP_SEMANTICS (directories)
            IntPtr h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
            if (h == Invalid) { error = Marshal.GetLastWin32Error(); return null; }
            try
            {
                StringBuilder sb = new StringBuilder(2048);
                uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
                if (n == 0 || n >= sb.Capacity) { error = Marshal.GetLastWin32Error(); return null; }
                return sb.ToString();
            }
            finally { CloseHandle(h); }
        }
    }
}
'@

function Resolve-EfcFinalPath {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path
    )

    Set-StrictMode -Version Latest

    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) }
    catch { return [pscustomobject]@{ Path = $Path; Resolved = $false } }

    $textual = [pscustomobject]@{ Path = $full; Resolved = $false }

    try {
        if (-not ('Efc.PathNative' -as [type])) {
            Add-Type -TypeDefinition $script:EfcPathNativeSource -ErrorAction Stop
        }
    }
    catch {
        Write-Verbose "Native path resolution unavailable: $($_.Exception.Message)"
        return $textual
    }

    $cur = $full.TrimEnd('\')
    if ($cur -match '^[A-Za-z]:$') { $cur = $cur + '\' }

    $tail = New-Object 'System.Collections.Generic.List[string]'
    while ($cur -and -not (Test-Path -LiteralPath $cur)) {
        # Plain string operations: Split-Path goes through the provider and throws
        # for a drive letter that does not exist.
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cur) { return $textual }
        $tail.Insert(0, [System.IO.Path]::GetFileName($cur))
        $cur = $parent
    }

    try {
        $err   = 0
        $final = [Efc.PathNative]::FinalPath($cur, [ref] $err)
        if ($null -eq $final) {
            Write-Verbose "GetFinalPathNameByHandle failed for '$cur' (Win32 error $err)."
            return $textual
        }

        $plain = ConvertTo-EfcPlainPath -Path $final
        if ($tail.Count -gt 0) {
            $plain = $plain.TrimEnd('\') + '\' + ($tail -join '\')
        }
        return [pscustomobject]@{ Path = $plain; Resolved = $true }
    }
    catch {
        Write-Verbose "Native path resolution failed: $($_.Exception.Message)"
        return $textual
    }
}
