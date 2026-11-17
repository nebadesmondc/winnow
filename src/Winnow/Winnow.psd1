@{
    RootModule        = 'Winnow.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7c4e1a2-9d3f-4a58-8e21-6f0c5d9b3a74'
    Author            = 'Winnow contributors'
    CompanyName       = 'Winnow contributors'
    Copyright         = '(c) Winnow contributors. MIT License.'
    Description       = 'Finds the space developer tools quietly take on your Windows system drive - package caches, app caches, leftovers - and reclaims it safely: read-only by default, offline, no admin rights, and every removal explained first.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-WinnowReport'
        'Get-WinnowRule'
        'Invoke-Winnow'
        'Invoke-WinnowClean'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('winnow')

    PrivateData = @{
        PSData = @{
            Tags         = @('Disk', 'DiskSpace', 'Cleanup', 'Cache', 'Developer', 'Windows')
            LicenseUri   = 'https://opensource.org/license/mit'
            ReleaseNotes = 'Pre-release. Scan and clean of developer tool caches with a deny-first guard; see README.md for status.'
        }
    }
}
