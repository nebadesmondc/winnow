# Older versions apps keep after updating. Your call: removing one goes to
# the Recycle Bin.

@(

    @{
        Id          = 'stale.vscode.build'
        Title       = 'Older editor build'
        Verdict     = 'YourCall'
        Discover    = { Get-WinnowVSCodeBuildCandidate }
        MinBytes    = 50MB
        Consequence = 'An older build kept beside the one the editor runs from. Nothing uses it; removing it sends it to the Recycle Bin.'
    }

    @{
        Id          = 'stale.extension'
        Title       = 'Older editor extension'
        Verdict     = 'YourCall'
        Discover    = { Get-WinnowStaleExtensionCandidate }
        MinBytes    = 25MB
        Consequence = 'An extension version the editor no longer loads. Removing it sends it to the Recycle Bin; the editor must be closed first.'
    }

    @{
        Id          = 'stale.squirrel'
        Title       = 'Older app version'
        Verdict     = 'YourCall'
        Discover    = { Get-WinnowSquirrelVersionCandidate }
        MinBytes    = 50MB
        Consequence = 'A previous version the app keeps after updating itself, used only to roll back. Removing it sends it to the Recycle Bin.'
    }

)
