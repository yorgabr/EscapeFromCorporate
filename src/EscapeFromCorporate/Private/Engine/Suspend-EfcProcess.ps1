#Requires -Version 5.1
<#
.SYNOPSIS
    Suspends or resumes a process using ntdll (no admin required for own processes).

.DESCRIPTION
    robocopy has no native pause. This wrapper P/Invokes NtSuspendProcess /
    NtResumeProcess against a process the current user owns. It resolves and reuses
    the process handle, validates the NTSTATUS return, and gracefully reports failure
    so the caller can fall back to a soft-pause without terminating the transfer.

    Returns $false (never throws) on any failure, since pause is a best-effort UX
    feature and must never crash an in-flight transfer.

.PARAMETER ProcessId
    Target process id (must be owned by the current user).

.PARAMETER Action
    'Suspend' or 'Resume'.

.OUTPUTS
    [bool] indicating whether the native call reported STATUS_SUCCESS.

.NOTES
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>

# Script-scoped flag for ntdll P/Invoke type registration, initialized eagerly
# for the same Set-StrictMode reason documented in ConvertFrom-RobocopyLine.ps1:
# reading an unassigned $script: variable under Set-StrictMode -Version Latest
# throws rather than evaluating as falsy/$null.
$script:EfcNtdllLoaded = $false

function Suspend-EfcProcess {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [int] $ProcessId,
        [Parameter(Mandatory)] [ValidateSet('Suspend', 'Resume')] [string] $Action
    )

    Set-StrictMode -Version Latest

    if (-not $script:EfcNtdllLoaded) {
        $signature = @'
[DllImport("ntdll.dll", SetLastError = true)]
public static extern uint NtSuspendProcess(IntPtr processHandle);
[DllImport("ntdll.dll", SetLastError = true)]
public static extern uint NtResumeProcess(IntPtr processHandle);
'@
        try {
            Add-Type -MemberDefinition $signature -Name 'EfcNtProc' -Namespace 'Efc' -ErrorAction Stop
            $script:EfcNtdllLoaded = $true
        }
        catch {
            Write-Verbose "ntdll P/Invoke unavailable in this environment: $($_.Exception.Message)"
            return $false
        }
    }

    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop

        if ($proc.HasExited) {
            Write-Verbose "Process $ProcessId already exited; suspend/resume is a no-op."
            return $false
        }

        # Materialize the handle once (accessing .Handle forces the OS handle open).
        $handle = $proc.Handle

        $status = if ($Action -eq 'Suspend') {
            [Efc.EfcNtProc]::NtSuspendProcess($handle)
        }
        else {
            [Efc.EfcNtProc]::NtResumeProcess($handle)
        }

        # NTSTATUS: 0 == STATUS_SUCCESS. Anything else is a failure/warning code.
        if ($status -ne 0) {
            Write-Verbose ("Nt{0}Process returned NTSTATUS 0x{1:X8} for PID {2}." -f $Action, $status, $ProcessId)
            return $false
        }

        return $true
    }
    catch {
        Write-Verbose "Suspend/Resume failed for PID $ProcessId ($Action): $($_.Exception.Message). Soft-pause fallback."
        return $false
    }
}