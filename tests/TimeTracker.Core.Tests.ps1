#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure tracker logic.
    Time is injected everywhere, so these run in milliseconds and never sleep.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path (Join-Path $repoRoot 'src') 'TimeTracker.Core.psm1') -Force

    # A fixed clock keeps every assertion deterministic.
    $script:T0 = [datetime]'2026-01-15T09:00:00'

    function New-Pos {
        param([int]$X, [int]$Y)
        return [pscustomobject]@{ X = $X; Y = $Y }
    }
}

Describe 'Format-Span' {
    It 'formats zero' {
        Format-Span -Seconds 0 | Should -Be '00:00:00'
    }
    It 'formats seconds and minutes' {
        Format-Span -Seconds 61 | Should -Be '00:01:01'
    }
    It 'formats hours' {
        Format-Span -Seconds 3725 | Should -Be '01:02:05'
    }
    It 'does not roll over at 24 hours' {
        Format-Span -Seconds (25 * 3600) | Should -Be '25:00:00'
    }
    It 'clamps negatives to zero' {
        Format-Span -Seconds (-50) | Should -Be '00:00:00'
    }
}

Describe 'Resolve-TrackerConfig' {
    It 'returns defaults when there is no override' {
        $c = Resolve-TrackerConfig -Default (Get-TrackerDefault) -Override $null
        $c.idleSeconds | Should -Be 120
        $c.pollMs      | Should -Be 250
    }
    It 'applies a hashtable override' {
        $c = Resolve-TrackerConfig -Default (Get-TrackerDefault) -Override @{ idleSeconds = 30 }
        $c.idleSeconds | Should -Be 30
        $c.pollMs      | Should -Be 250
    }
    It 'applies a PSCustomObject override (the ConvertFrom-Json shape)' {
        $json = '{ "idleSeconds": 45, "alarmEnabled": false }' | ConvertFrom-Json
        $c = Resolve-TrackerConfig -Default (Get-TrackerDefault) -Override $json
        $c.idleSeconds  | Should -Be 45
        $c.alarmEnabled | Should -BeFalse
    }
    It 'ignores unknown keys from a stale config file' {
        $c = Resolve-TrackerConfig -Default (Get-TrackerDefault) -Override @{ nonsense = 'boom' }
        $c.ContainsKey('nonsense') | Should -BeFalse
    }
    It 'falls back to built-in defaults when none are supplied' {
        $c = Resolve-TrackerConfig -Override @{ idleSeconds = 77 }
        $c.idleSeconds | Should -Be 77
        $c.pollMs      | Should -Be 250
    }
    It 'does not mutate the defaults it was given' {
        $d = Get-TrackerDefault
        Resolve-TrackerConfig -Default $d -Override @{ idleSeconds = 999 } | Out-Null
        $d.idleSeconds | Should -Be 120
    }
}

Describe 'Test-CursorMoved' {
    It 'ignores jitter below the threshold' {
        Test-CursorMoved -Previous (New-Pos 100 100) -Current (New-Pos 101 101) -ThresholdPx 2 | Should -BeFalse
    }
    It 'detects movement at exactly the threshold' {
        Test-CursorMoved -Previous (New-Pos 100 100) -Current (New-Pos 102 100) -ThresholdPx 2 | Should -BeTrue
    }
    It 'detects vertical-only movement' {
        Test-CursorMoved -Previous (New-Pos 100 100) -Current (New-Pos 100 140) -ThresholdPx 2 | Should -BeTrue
    }
    It 'reports no movement for an identical position' {
        Test-CursorMoved -Previous (New-Pos 7 7) -Current (New-Pos 7 7) -ThresholdPx 2 | Should -BeFalse
    }
}

Describe 'Step-Tracker - active time accounting' {
    It 'banks the tick delta while the cursor moves' {
        $s = New-TrackerState -Now $script:T0
        $r = Step-Tracker -State $s -Now $script:T0.AddSeconds(0.25) -LastTick $script:T0 -Moved $true
        $r.Status | Should -Be 'MOVING'
        $s.activeSeconds | Should -Be 0.25
    }
    It 'accumulates across many ticks' {
        $s = New-TrackerState -Now $script:T0
        $prev = $script:T0
        foreach ($i in 1..8) {
            $now = $script:T0.AddSeconds(0.25 * $i)
            Step-Tracker -State $s -Now $now -LastTick $prev -Moved $true | Out-Null
            $prev = $now
        }
        $s.activeSeconds | Should -Be 2.0
    }
    It 'discards an implausible delta from sleep or suspension' {
        $s = New-TrackerState -Now $script:T0
        # Machine slept for an hour, then the cursor moved.
        Step-Tracker -State $s -Now $script:T0.AddHours(1) -LastTick $script:T0 -Moved $true | Out-Null
        $s.activeSeconds | Should -Be 0
    }
}

Describe 'Step-Tracker - the 2 minute idle alarm' {
    It 'stays quiet before the threshold' {
        $s = New-TrackerState -Now $script:T0
        $r = Step-Tracker -State $s -Now $script:T0.AddSeconds(119) -LastTick $script:T0.AddSeconds(118.75) -Moved $false
        $r.Status     | Should -Be 'IDLE'
        $r.StartAlarm | Should -BeFalse
        $r.Notify     | Should -BeFalse
    }
    It 'fires the alarm and the notification at exactly 120 seconds' {
        $s = New-TrackerState -Now $script:T0
        $r = Step-Tracker -State $s -Now $script:T0.AddSeconds(120) -LastTick $script:T0.AddSeconds(119.75) -Moved $false
        $r.StartAlarm  | Should -BeTrue
        $r.Notify      | Should -BeTrue
        $r.NotifyText  | Should -Match 'No cursor movement'
        $s.idleEpisodes | Should -Be 1
    }
    It 'fires only once per idle episode' {
        $s = New-TrackerState -Now $script:T0
        $prev = $script:T0
        $fires = 0
        foreach ($sec in 120, 150, 200, 400) {
            $now = $script:T0.AddSeconds($sec)
            $r = Step-Tracker -State $s -Now $now -LastTick $prev -Moved $false
            if ($r.StartAlarm) { $fires++ }
            $prev = $now
        }
        $fires | Should -Be 1
        $s.idleEpisodes | Should -Be 1
    }
    It 're-arms after the cursor moves again' {
        $s = New-TrackerState -Now $script:T0
        Step-Tracker -State $s -Now $script:T0.AddSeconds(120) -LastTick $script:T0.AddSeconds(119) -Moved $false | Out-Null
        $s.alarmFired | Should -BeTrue

        $wake = $script:T0.AddSeconds(130)
        $r = Step-Tracker -State $s -Now $wake -LastTick $script:T0.AddSeconds(129) -Moved $true
        $r.StopAlarm  | Should -BeTrue
        $s.alarmFired | Should -BeFalse

        $r2 = Step-Tracker -State $s -Now $wake.AddSeconds(120) -LastTick $wake.AddSeconds(119) -Moved $false
        $r2.StartAlarm  | Should -BeTrue
        $s.idleEpisodes | Should -Be 2
    }
    It 'honours a custom idle threshold' {
        $cfg = Resolve-TrackerConfig -Default (Get-TrackerDefault) -Override @{ idleSeconds = 10 }
        $s = New-TrackerState -Now $script:T0
        $r = Step-Tracker -State $s -Now $script:T0.AddSeconds(10) -LastTick $script:T0.AddSeconds(9.75) -Moved $false -Config $cfg
        $r.StartAlarm | Should -BeTrue
    }
    It 'suppresses only the toast when notifications are disabled' {
        $cfg = Resolve-TrackerConfig -Default (Get-TrackerDefault) -Override @{ notificationEnabled = $false }
        $s = New-TrackerState -Now $script:T0
        $r = Step-Tracker -State $s -Now $script:T0.AddSeconds(120) -LastTick $script:T0.AddSeconds(119) -Moved $false -Config $cfg
        $r.StartAlarm | Should -BeTrue
        $r.Notify     | Should -BeFalse
    }
    It 'tracks the longest idle stretch of the day' {
        $s = New-TrackerState -Now $script:T0
        Step-Tracker -State $s -Now $script:T0.AddSeconds(300) -LastTick $script:T0.AddSeconds(299) -Moved $false | Out-Null
        [math]::Round($s.longestIdle) | Should -Be 300
    }
}

Describe 'Step-Tracker - lock screen suppression' {
    It 'never alarms while blocked, however long the stillness' {
        $s = New-TrackerState -Now $script:T0
        $r = Step-Tracker -State $s -Now $script:T0.AddHours(3) -LastTick $script:T0 -Moved $false -Blocked $true
        $r.Status     | Should -Be 'LOCKED'
        $r.StartAlarm | Should -BeFalse
        $r.Notify     | Should -BeFalse
        $s.idleEpisodes | Should -Be 0
    }
    It 'banks no active time while blocked, even if the cursor reports movement' {
        $s = New-TrackerState -Now $script:T0
        Step-Tracker -State $s -Now $script:T0.AddSeconds(0.25) -LastTick $script:T0 -Moved $true -Blocked $true | Out-Null
        $s.activeSeconds | Should -Be 0
    }
    It 'does not ambush the user with an instant alarm after unlocking' {
        $s = New-TrackerState -Now $script:T0
        # Locked for an hour.
        $lockEnd = $script:T0.AddHours(1)
        Step-Tracker -State $s -Now $lockEnd -LastTick $script:T0 -Moved $false -Blocked $true | Out-Null
        # First unlocked tick, still no cursor movement.
        $r = Step-Tracker -State $s -Now $lockEnd.AddSeconds(0.25) -LastTick $lockEnd -Moved $false
        $r.StartAlarm  | Should -BeFalse
        $r.IdleSeconds | Should -BeLessThan 1
    }
    It 'stops a ringing alarm the moment the screen locks' {
        $s = New-TrackerState -Now $script:T0
        Step-Tracker -State $s -Now $script:T0.AddSeconds(120) -LastTick $script:T0.AddSeconds(119) -Moved $false | Out-Null
        $r = Step-Tracker -State $s -Now $script:T0.AddSeconds(121) -LastTick $script:T0.AddSeconds(120) -Moved $false -Blocked $true
        $r.StopAlarm | Should -BeTrue
    }
    It 'gives blocked precedence over paused and moved' {
        $s = New-TrackerState -Now $script:T0
        $r = Step-Tracker -State $s -Now $script:T0.AddSeconds(1) -LastTick $script:T0 -Moved $true -Paused $true -Blocked $true
        $r.Status | Should -Be 'LOCKED'
    }
}

Describe 'Step-Tracker - pause' {
    It 'banks nothing and never alarms while paused' {
        $s = New-TrackerState -Now $script:T0
        $r = Step-Tracker -State $s -Now $script:T0.AddHours(2) -LastTick $script:T0 -Moved $true -Paused $true
        $r.Status        | Should -Be 'PAUSED'
        $r.StartAlarm    | Should -BeFalse
        $s.activeSeconds | Should -Be 0
    }
}

Describe 'ConvertTo-DayRecord' {
    It 'produces the persisted shape' {
        $s = New-TrackerState -Now $script:T0 -ActiveSeconds 3725.456 -IdleEpisodes 4 -LongestIdle 91.2
        $rec = ConvertTo-DayRecord -State $s -SavedAt $script:T0

        $rec.date               | Should -Be '2026-01-15'
        $rec.activeSeconds      | Should -Be 3725.46
        $rec.activeFormatted    | Should -Be '01:02:05'
        $rec.idleEpisodes       | Should -Be 4
        $rec.longestIdleSeconds | Should -Be 91.2
    }
    It 'round-trips through JSON' {
        $s = New-TrackerState -Now $script:T0 -ActiveSeconds 100 -IdleEpisodes 2 -LongestIdle 10
        $back = (ConvertTo-DayRecord -State $s -SavedAt $script:T0 | ConvertTo-Json) | ConvertFrom-Json
        $back.activeSeconds | Should -Be 100
        $back.idleEpisodes  | Should -Be 2
    }
}
