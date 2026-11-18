# Files Windows manages. Winnow explains them and gives the official steps;
# it never changes them.

@(

    @{
        Id          = 'system.pagefile'
        Title       = 'Windows pagefile'
        Verdict     = 'HandsOff'
        Discover    = { Get-WinnowPagefileCandidate }
        Reclaim     = @(@{ Type = 'ReportOnly' })
        MinBytes    = 512MB
        Consequence = 'Windows moves memory here when RAM runs short. A pagefile that is too small causes out-of-memory errors and crashes.'
        Steps       = @(
            'Run SystemPropertiesPerformance.exe, open Advanced, then Virtual memory > Change.'
            'Untick "Automatically manage", choose Custom size, and set both sizes above the peak use shown here.'
            'The change needs administrator rights and a restart.'
        )
        Docs        = 'https://learn.microsoft.com/troubleshoot/windows-client/performance/introduction-to-the-page-file'
    }

    @{
        Id          = 'system.hiberfil'
        Title       = 'Hibernation file'
        Verdict     = 'HandsOff'
        Discover    = { Get-WinnowHiberfilCandidate }
        Reclaim     = @(@{ Type = 'ReportOnly' })
        MinBytes    = 512MB
        Consequence = 'Holds the contents of memory for hibernation and Fast Startup. Turning hibernation off deletes it and turns both off.'
        Steps       = @(
            'To keep Fast Startup and give up hibernation: powercfg /h /type reduced (about half the size).'
            'To give up both: powercfg /h off (the file is deleted).'
            'Both need an administrator terminal.'
        )
        Docs        = 'https://learn.microsoft.com/windows-hardware/design/device-experiences/powercfg-command-line-options'
    }

)
