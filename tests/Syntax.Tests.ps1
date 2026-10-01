#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Every shipped PowerShell file must parse. This is the cheapest possible
    guard against a typo reaching a user, since the GUI script itself cannot
    be executed headlessly in CI.

    Note: Pester 5 exposes -ForEach hashtable keys as variables directly.
    A param() block here would silently receive nothing and every test would
    pass against a null path.
#>

BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:psFiles = @(
        Get-ChildItem -Path $repoRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' |
            Where-Object { $_.FullName -notmatch '\\(artifacts|data|\.git)\\' } |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }
    )
}

Describe 'PowerShell files parse cleanly' {

    # The count is captured at discovery time. Reading $script:psFiles inside
    # the test body would see $null, and @($null).Count is 1 in PowerShell, so
    # the assertion would pass even when zero files were discovered.
    It 'discovers the expected PowerShell files' -ForEach @(
        @{ Found = @($script:psFiles).Count }
    ) {
        $Found | Should -BeGreaterThan 5
    }

    It '<Name> has no syntax errors' -ForEach $script:psFiles {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null

        $detail = 'no parse errors'
        if (@($errors).Count -gt 0) {
            $detail = (@($errors) | ForEach-Object {
                'line ' + $_.Extent.StartLineNumber + ': ' + $_.Message
            }) -join ' | '
        }

        @($errors).Count | Should -Be 0 -Because $detail
    }
}

Describe 'Core module surface' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path (Join-Path $root 'src') 'TimeTracker.Core.psm1') -Force
    }

    It 'exports every function the GUI depends on' {
        $exported = (Get-Module TimeTracker.Core).ExportedFunctions.Keys
        foreach ($fn in 'Format-Span', 'Get-TrackerDefault', 'Resolve-TrackerConfig',
                        'Test-CursorMoved', 'New-TrackerState', 'Step-Tracker', 'ConvertTo-DayRecord') {
            $exported | Should -Contain $fn
        }
    }

    It 'uses only approved PowerShell verbs' {
        $approved = (Get-Verb).Verb
        foreach ($fn in (Get-Module TimeTracker.Core).ExportedFunctions.Keys) {
            ($fn -split '-')[0] | Should -BeIn $approved
        }
    }
}
