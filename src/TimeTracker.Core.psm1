<#
    TimeTracker.Core.psm1
    Pure, UI-free, clock-free logic for the time tracker.
    Every function here is deterministic: time is injected, never read from
    Get-Date. That is what makes the idle rule, the lock-screen suppression
    and the end-of-day rollover testable in CI.
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
        showDailySummary    = $true
        saveEverySeconds    = 30
        windowX             = -1
        windowY             = -1
    }
}

function Get-TrackerSettingSpec {
    <#
        Data-driven description of the user-editable settings. The settings
        dialog is generated from this list, so adding a setting here is the
        only change needed to expose it in the UI.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param()

    return @(
        [pscustomobject]@{ Name = 'idleSeconds';         Label = 'Alarm after (seconds of stillness)'; Kind = 'int';  Min = 5;  Max = 7200 }
        [pscustomobject]@{ Name = 'alarmSeconds';        Label = 'Alarm length (seconds)';             Kind = 'int';  Min = 1;  Max = 300 }
        [pscustomobject]@{ Name = 'movementThresholdPx'; Label = 'Ignore movement under (pixels)';     Kind = 'int';  Min = 1;  Max = 50 }
        [pscustomobject]@{ Name = 'pollMs';              Label = 'Sampling interval (ms)';             Kind = 'int';  Min = 50; Max = 5000 }
        [pscustomobject]@{ Name = 'alarmEnabled';        Label = 'Play alarm sound';                   Kind = 'bool' }
        [pscustomobject]@{ Name = 'notificationEnabled'; Label = 'Show Windows notification';          Kind = 'bool' }
        [pscustomobject]@{ Name = 'suppressWhenLocked';  Label = 'Stay silent while locked';           Kind = 'bool' }
        [pscustomobject]@{ Name = 'showDailySummary';    Label = 'Show summary when the day ends';     Kind = 'bool' }
    )
}

function Test-TrackerSetting {
    <#
        Validate one setting value coming from the settings dialog.
        Returns @{ Valid; Value; Message } - Value is the normalised value,
        so the caller never has to parse anything itself.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    $spec = Get-TrackerSettingSpec | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $spec) {
        return @{ Valid = $false; Value = $null; Message = ('Unknown setting: ' + $Name) }
    }

    if ($spec.Kind -eq 'bool') {
        if ($Value -is [bool]) {
            return @{ Valid = $true; Value = $Value; Message = '' }
        }
        $text = ([string]$Value).Trim()
        if ($text -match '^(?i)(true|1|yes|on)$')  { return @{ Valid = $true; Value = $true;  Message = '' } }
        if ($text -match '^(?i)(false|0|no|off)$') { return @{ Valid = $true; Value = $false; Message = '' } }
        return @{ Valid = $false; Value = $null; Message = ($spec.Label + ' must be true or false') }
    }

    $parsed = 0
    if (-not [int]::TryParse(([string]$Value).Trim(), [ref]$parsed)) {
        return @{ Valid = $false; Value = $null; Message = ($spec.Label + ' must be a whole number') }
    }
    if ($parsed -lt $spec.Min -or $parsed -gt $spec.Max) {
        return @{
            Valid   = $false
            Value   = $null
            Message = ($spec.Label + ' must be between ' + $spec.Min + ' and ' + $spec.Max)
        }
    }
    return @{ Valid = $true; Value = $parsed; Message = '' }
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
    <#  True when the cursor shifted at least ThresholdPx on either axis.  #>
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

function Format-DaySummary {
    <#  Human-readable end-of-day report shown when the date rolls over.  #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][datetime]$Day,
        [Parameter(Mandatory)][double]$ActiveSeconds,
        [int]$IdleEpisodes = 0,
        [double]$LongestIdleSeconds = 0
    )

    $lines = @(
        $Day.ToString('dddd, dd MMMM yyyy'),
        '',
        ('Total working time : ' + (Format-Span $ActiveSeconds)),
        ('Idle episodes      : ' + $IdleEpisodes),
        ('Longest idle       : ' + (Format-Span $LongestIdleSeconds))
    )
    return ($lines -join [Environment]::NewLine)
}

function Step-Tracker {
    <#
        The heart of the tracker: one deterministic state transition.

        Precedence: day rollover beats everything, then Blocked, then Paused,
        then Moved. A locked workstation must never alarm, never notify and
        never bank time, whatever the cursor coordinates say.
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
        Status             = 'MOVING'
        IdleSeconds        = 0.0
        StartAlarm         = $false
        StopAlarm          = $false
        Notify             = $false
        NotifyTitle        = ''
        NotifyText         = ''
        DayEnded           = $false
        EndedDay           = $null
        EndedActiveSeconds = 0.0
        EndedIdleEpisodes  = 0
        EndedLongestIdle   = 0.0
        State              = $State
    }

    # The date changed under us: hand the finished day back to the caller so it
    # can be persisted and reported before a fresh day starts.
    if ($Now.Date -ne [datetime]$State.day) {
        $result.DayEnded           = $true
        $result.EndedDay           = [datetime]$State.day
        $result.EndedActiveSeconds = [double]$State.activeSeconds
        $result.EndedIdleEpisodes  = [int]$State.idleEpisodes
        $result.EndedLongestIdle   = [double]$State.longestIdle
        $result.Status             = 'DAYEND'
        $result.StopAlarm          = $true
        return $result
    }

    if ($Blocked) {
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

Export-ModuleMember -Function Format-Span, Get-TrackerDefault, Get-TrackerSettingSpec,
    Test-TrackerSetting, Resolve-TrackerConfig, Test-CursorMoved, New-TrackerState,
    Format-DaySummary, Step-Tracker, ConvertTo-DayRecord
