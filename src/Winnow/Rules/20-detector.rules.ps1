# Generic detectors (see Private\Detectors.ps1).

@(

    @{
        Id       = 'appcache.conventional'
        Title    = 'Application cache directories'
        Verdict  = 'Clean'
        Discover = { Get-WinnowConventionalCacheCandidate }
        MinBytes = 25MB
        Consequence = 'Applications rebuild these on next launch. Browser and app state - logins, bookmarks, settings, extensions - is on a separate exclusion list and is never included here.'
    }

    @{
        Id       = 'installer.applied'
        Title    = 'Installers already applied'
        Verdict  = 'Clean'
        Discover = { Get-WinnowAppliedInstallerCandidate -MinAgeDays 14 }
        MinBytes = 20MB
        Consequence = 'Removes downloaded installer payloads whose update has already been applied. An update you have not applied yet is younger than the 14-day floor and is left alone.'
    }

)
