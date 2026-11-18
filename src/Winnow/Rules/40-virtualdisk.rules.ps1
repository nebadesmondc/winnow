# Virtual disks. Each holds a whole machine; Winnow never deletes one.

@(

    @{
        Id          = 'vdisk.wsl'
        Title       = 'WSL distribution'
        Verdict     = 'Move'
        Discover    = { Get-WinnowWslDiskCandidate }
        Reclaim     = @(@{ Type = 'ReportOnly' })
        MinBytes    = 512MB
        Consequence = "Holds a Linux distribution: its files, packages and home folder. Deleting it deletes the distribution."
        Docs        = 'https://learn.microsoft.com/windows/wsl/basic-commands'
    }

    @{
        Id          = 'vdisk.docker'
        Title       = 'Docker Desktop data disk'
        Verdict     = 'Move'
        Discover    = { Get-WinnowDockerDiskCandidate }
        Reclaim     = @(@{ Type = 'ReportOnly' })
        MinBytes    = 512MB
        Consequence = "Holds Docker Desktop's images, containers, volumes and build cache. Deleting it deletes them all."
        Steps       = @(
            'docker system df shows what is inside; docker system prune removes stopped containers, unused networks and images, and build cache.'
            'To move it: Docker Desktop > Settings > Resources > Advanced > Disk image location.'
        )
        Docs        = 'https://docs.docker.com/desktop/settings-and-maintenance/settings/'
    }

    @{
        Id          = 'vdisk.other'
        Title       = 'Virtual disk'
        Verdict     = 'YourCall'
        Discover    = { Get-WinnowOtherDiskCandidate }
        Reclaim     = @(@{ Type = 'ReportOnly' })
        MinBytes    = 1GB
        Consequence = 'The disk of a virtual machine or emulator. Deleting it deletes that machine; remove it with the tool that created it.'
    }

)
