@{
    RootModule        = 'Winnow.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7c4e1a2-9d3f-4a58-8e21-6f0c5d9b3a74'
    Author            = 'Winnow contributors'
    CompanyName       = 'Winnow contributors'
    Copyright         = '(c) Winnow contributors. MIT License.'
    Description       = 'Shows where the space on your Windows system drive went and gets it back safely: a read-only map of the drive, a verdict and a cost for every large item, guarded removal of only what you approve, and moves of caches and WSL distributions to another drive that undo reverses. Offline, no admin rights.'

    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        'Get-WinnowReport'
        'Get-WinnowRule'
        'Invoke-Winnow'
        'Invoke-WinnowClean'
        'Invoke-WinnowMove'
        'Undo-WinnowMove'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('winnow')

    PrivateData = @{
        PSData = @{
            Tags         = @('Disk', 'DiskSpace', 'Cleanup', 'Cache', 'WSL', 'Docker', 'Developer', 'Windows')
            ProjectUri   = 'https://github.com/nebadesmondc/winnow'
            LicenseUri   = 'https://github.com/nebadesmondc/winnow/blob/master/LICENSE'
            ReleaseNotes = 'https://github.com/nebadesmondc/winnow/releases'
        }
    }
}
