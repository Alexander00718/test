<#
    TimeTracker.Core.psm1
    Pure, UI-free, clock-free logic for the time tracker.
    Every function here is deterministic: time is injected, never read from
    Get-Date. That is what makes the 2-minute idle rule and the lock-screen
    suppression testable in CI.
#>

Set-StrictMode -Version Latest

function Format-Span {
    <#  Seconds -> 'HH:MM:SS' (hours are not capped at 24)  #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][double]$Seconds)

    $safe = [math]::Max(0, $Seconds)
    $ts = [TimeSpan]::FromSeconds($safe)
    return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Get-TrackerDefault {
    <#  The canonical default configuration.  #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        idleSeconds         = 120
        pollMs              = 250
        movementThresholdPx = 2
        alarmEnabled        = $true
        alarmSeconds        = 15
        alarmSoundPath      = ''
        notificationEnabled = $true
        suppressWhenLocked  = $true
        saveEverySeconds    = 30
        windowX             = -1
        windowY             = -1
    }
}

function Resolve-TrackerConfig {
    <#  Overlay user config onto defaults. Unknown keys are ignored, so a
        stale config.json can never inject surprise settings.  #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable]$Default,
        [object]$Override
    )

    if (-not $Default) { $Default = Get-TrackerDefault }
    $merged = @{}
    foreach ($k in $Default.Keys) { $merged[$k] = $Default[$k] }
    if ($null -eq $Override) { return $merged }

    $pairs = @()
    if ($Override -is [hashtable]) {
        foreach ($k in $Override.Keys) { $pairs += , @($k, $Override[$k]) }
    } else {
        foreach ($p in $Override.PSObject.Properties) { $pairs += , @($p.Name, $p.Value) }
    }
    foreach ($pair in $pairs) {
        if ($merged.ContainsKey($pair[0]) -and $null -ne $pair[1]) { $merged[$pair[0]] = $pair[1] }
    }
    return $merged
}

function Test-CursorMoved {
    <#  True when the cursor shifted at least ThresholdPx on either axis.
        The threshold kills sub-pixel jitter and optical-mouse drift.  #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object]$Previous,
        [Parameter(Mandatory)][object]$Current,
        [int]$ThresholdPx = 2
    )

    $dx = [math]::Abs([int]$Current.X - [int]$Previous.X)
    $dy = [math]::Abs([int]$Current.Y - [int]$Previous.Y)
    return ($dx -ge $ThresholdPx -or $dy -ge $ThresholdPx)
}

function New-TrackerState {
    <#  Fresh mutable state for one tracked day.  #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [datetime]$Now = [datetime]::Now,
        [double]$ActiveSeconds = 0.0,
        [int]$IdleEpisodes = 0,
        [double]$LongestIdle = 0.0
    )

    return @{
        day           = $Now.Date
        activeSeconds = $ActiveSeconds
        idleEpisodes  = $IdleEpisodes
        longestIdle   = $LongestIdle
        lastMoveTime  = $Now
        alarmFired    = $false
    }
}

function Step-Tracker {
    <#
        The heart of the tracker: one deterministic state transition.

        Precedence is deliberate - Blocked beats Paused beats Moved. A locked
        workstation must never alarm, never notify, and never bank time, no
        matter what the cursor coordinates say.

        Returns the decision; the caller applies it to sound and pixels.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][datetime]$LastTick,
        [bool]$Moved   = $false,
        [bool]$Blocked = $false,
        [bool]$Paused  = $false,
        [hashtable]$Config
    )

    if (-not $Config) { $Config = Get-TrackerDefault }
    $idleLimit = [double]$Config.idleSeconds
    $delta = ($Now - $LastTick).TotalSeconds

    $result = @{
        Status      = 'MOVING'
        IdleSeconds = 0.0
        StartAlarm  = $false
        StopAlarm   = $false
        Notify      = $false
        NotifyTitle = ''
        NotifyText  = ''
        State       = $State
    }

    if ($Blocked) {
        # Lock screen or screen saver: freeze everything and re-arm the idle
        # clock so returning to the desk does not fire an instant alarm.
        $State.alarmFired   = $false
        $State.lastMoveTime = $Now
        $result.Status      = 'LOCKED'
        $result.StopAlarm   = $true
        return $result
    }

    if ($Paused) {
        $State.lastMoveTime = $Now
        $result.Status      = 'PAUSED'
        $result.StopAlarm   = $true
        return $result
    }

    if ($Moved) {
        # Only bank plausible deltas. A huge delta means the process was
        # suspended or the machine slept; that time was not work.
        if ($delta -gt 0 -and $delta -le $idleLimit) {
            $State.activeSeconds += $delta
        }
        $State.lastMoveTime = $Now
        $State.alarmFired   = $false
        $result.Status      = 'MOVING'
        $result.StopAlarm   = $true
        return $result
    }

    $idleFor = ($Now - $State.lastMoveTime).TotalSeconds
    if ($idleFor -gt $State.longestIdle) { $State.longestIdle = $idleFor }
    $result.Status      = 'IDLE'
    $result.IdleSeconds = $idleFor

    if (-not $State.alarmFired -and $idleFor -ge $idleLimit) {
        $State.alarmFired    = $true
        $State.idleEpisodes += 1
        $result.StartAlarm   = $true
        $result.Notify       = [bool]$Config.notificationEnabled
        $result.NotifyTitle  = 'Time Tracker - you stopped moving'
        $result.NotifyText   = ('No cursor movement for {0}. Active time today: {1}' -f (Format-Span $idleFor), (Format-Span $State.activeSeconds))
    }

    return $result
}

function ConvertTo-DayRecord {
    <#  State -> the object persisted as one JSON file per day.  #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [datetime]$SavedAt = [datetime]::Now
    )

    return [ordered]@{
        date               = ([datetime]$State.day).ToString('yyyy-MM-dd')
        activeSeconds      = [math]::Round([double]$State.activeSeconds, 2)
        activeFormatted    = (Format-Span ([double]$State.activeSeconds))
        idleEpisodes       = [int]$State.idleEpisodes
        longestIdleSeconds = [math]::Round([double]$State.longestIdle, 2)
        lastSaved          = $SavedAt.ToString('s')
    }
}

Export-ModuleMember -Function Format-Span, Get-TrackerDefault, Resolve-TrackerConfig,
    Test-CursorMoved, New-TrackerState, Step-Tracker, ConvertTo-DayRecord
