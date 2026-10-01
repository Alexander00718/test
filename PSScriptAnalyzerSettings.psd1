@{
    # Warnings are reported always; CI runs -Strict so warnings break the build.
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Build.ps1 is a console tool; Write-Host is the correct channel.
        'PSAvoidUsingWriteHost',

        # The tracker deliberately swallows failures from best-effort calls
        # (sound device missing, tray unavailable) rather than killing the app.
        'PSAvoidUsingEmptyCatchBlock',

        # WinForms event scriptblocks assign script-scope state that the
        # analyzer cannot see being read from the timer callback.
        'PSUseDeclaredVarsMoreThanAssignments',

        # Event handler signatures require ($s, $e) even when unused.
        'PSReviewUnusedParameter',

        # New-TrackerState, New-Pos and Start-/Stop-TrackerAlarm mutate only
        # in-memory state or a local sound device. -WhatIf/-Confirm on them
        # would be noise. NOTE: the rule is ...Functions, not ...Verbs - the
        # latter is not a real rule name and silently excluded nothing.
        'PSUseShouldProcessForStateChangingFunctions',

        # Pure formatting opinions. Excluded deliberately: with -Strict enabled,
        # these would fail pull requests over alignment and indentation instead
        # of over defects, which trains people to ignore the linter.
        'PSUseConsistentIndentation',
        'PSUseConsistentWhitespace',
        'PSAlignAssignmentStatement',

        # Tests read far better as 'Format-Span -Seconds 0' than fully named
        # everywhere; this rule fires on ordinary readable Pester calls.
        'PSAvoidUsingPositionalParameters',

        # This settings file is itself a .psd1, and the rule treats every
        # .psd1 as a candidate module manifest. Without this exclusion a
        # -Strict CI run fails on the linter's own configuration.
        'PSMissingModuleManifestField'
    )
}
