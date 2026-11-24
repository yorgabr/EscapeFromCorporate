@{
    RootModule        = 'EscapeFromCorporate.psm1'
    ModuleVersion     = '3.0.0'
    GUID              = 'e3f8a1c2-6b4d-4a90-9f2e-1d7c5b8a3e46'
    Author            = 'Yorga Babuscan'
    CompanyName       = 'Yorga Babuscan'
    Copyright         = '(c) 2025 Yorga Babuscan. Licensed under the Apache License 2.0.'
    Description       = 'Secure, resumable file dump utility for locked-down corporate Windows environments. Wraps robocopy with asynchronous log polling, idempotent state persistence, live progress UI, post-copy integrity validation, and rsync-style Source/Destination syntax. No admin privileges required.'
    # Enables 'Update-Help' to fetch refreshed help from a hosted CAB in the future.
    HelpInfoURI       = 'https://github.com/yorgabr/EscapeFromCorporate/raw/main/help/'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Invoke-EfcJob',
        'Get-EfcJobState',
        'Resume-EfcJob',
        'Clear-EfcState'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('efc', 'Escape-FromCorporate', 'Invoke-Efc')

    PrivateData = @{
        PSData = @{
            Tags         = @('robocopy', 'backup', 'file-copy', 'nas', 'resumable', 'corporate', 'windows', 'no-admin', 'rsync')
            LicenseUri   = 'https://www.apache.org/licenses/LICENSE-2.0'
            ProjectUri   = 'https://github.com/yorgabr/EscapeFromCorporate'
            ReleaseNotes = 'See CHANGELOG.md for the full release history. v2.0.0 is a BREAKING CHANGE: Source/Destination now use rsync-style trailing-slash semantics.'
        }
    }
}