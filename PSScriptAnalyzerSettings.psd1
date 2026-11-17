@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'                         # console UI
        'PSAvoidUsingEmptyCatchBlock'                   # best-effort probes
        'PSUseShouldProcessForStateChangingFunctions'   # internal helpers; public commands support -WhatIf
        'PSUseSingularNouns'
    )
}
