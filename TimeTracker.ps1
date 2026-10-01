#Requires -Version 5.1
<#
    TimeTracker.ps1
    Windows tray app: measures how long the mouse cursor is actually moving,
    alarms when it goes still for too long, and stays silent on the lock screen.

    All decision logic lives in src/TimeTracker.Core.psm1 so it can be unit
    tested. This file is the shell: Win32 probes, sound, and pixels.
#>
[CmdletBinding()]
param(
    [int]$IdleSeconds = 0,
    [switch]$NoAlarm,
    [switch]$NoNotify
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- paths ----
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$dataDir    = Join-Path $root 'data'
$configPath = Join-Path $root 'config.json'
$corePath   = Join-Path (Join-Path $root 'src') 'TimeTracker.Core.psm1'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

Import-Module $corePath -Force

# --------------------------------------------------------------- config ----
$loaded = $null
if (Test-Path $configPath) {
    try { $loaded = Get-Content $configPath -Raw | ConvertFrom-Json }
    catch { Write-Warning ('config.json unreadable, using defaults: ' + $_.Exception.Message) }
} else {
    (Get-TrackerDefault | ConvertTo-Json) | Set-Content -Path $configPath -Encoding UTF8
}
$cfg = Resolve-TrackerConfig -Default (Get-TrackerDefault) -Override $loaded
if ($IdleSeconds -gt 0) { $cfg.idleSeconds = $IdleSeconds }
if ($NoAlarm)  { $cfg.alarmEnabled = $false }
if ($NoNotify) { $cfg.notificationEnabled = $false }

# --------------------------------------------------------------- native ----
if (-not ('TTNative' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class TTNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT p);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseDesktop(IntPtr hDesktop);

    [DllImport("user32.dll")]
    private static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref bool pvParam, uint fWinIni);

    private const uint DESKTOP_SWITCHDESKTOP = 0x0100;
    private const uint SPI_GETSCREENSAVERRUNNING = 0x0072;

    public static POINT Cursor()
    {
        POINT p;
        GetCursorPos(out p);
        return p;
    }

    // The secure (lock) desktop cannot be opened from a normal user session,
    // so a failure here is a reliable "workstation is locked" signal.
    public static bool IsLocked()
    {
        IntPtr h = OpenInputDesktop(0, false, DESKTOP_SWITCHDESKTOP);
        if (h == IntPtr.Zero) { return true; }
        CloseDesktop(h);
        return false;
    }

    public static bool ScreenSaverRunning()
    {
        bool running = false;
        SystemParametersInfo(SPI_GETSCREENSAVERRUNNING, 0, ref running, 0);
        return running;
    }
}
'@
}

function Test-ScreenBlocked {
    [OutputType([bool])]
    param()
    if (-not $cfg.suppressWhenLocked) { return $false }
    try {
        if ([TTNative]::IsLocked()) { return $true }
        if ([TTNative]::ScreenSaverRunning()) { return $true }
    } catch { }
    if (Get-Process -Name 'LogonUI' -ErrorAction SilentlyContinue) { return $true }
    return $false
}

# ------------------------------------------------------------- day data ----
function Get-DayFile {
    param([datetime]$Day)
    return Join-Path $dataDir ($Day.ToString('yyyy-MM-dd') + '.json')
}

function Import-DayData {
    param([datetime]$Day)
    $state = New-TrackerState -Now $Day
    $f = Get-DayFile -Day $Day
    if (Test-Path $f) {
        try {
            $d = Get-Content $f -Raw | ConvertFrom-Json
            $state.activeSeconds = [double]$d.activeSeconds
            $state.idleEpisodes  = [int]$d.idleEpisodes
            $state.longestIdle   = [double]$d.longestIdleSeconds
        } catch { }
    }
    $state.lastMoveTime = Get-Date
    return $state
}

function Save-DayData {
    param([hashtable]$State)
    try {
        $record = ConvertTo-DayRecord -State $State -SavedAt (Get-Date)
        ($record | ConvertTo-Json) | Set-Content -Path (Get-DayFile -Day ([datetime]$State.day)) -Encoding UTF8
    } catch { }
}

$script:state = Import-DayData -Day (Get-Date)

# ---------------------------------------------------------------- alarm ----
$soundPath = [string]$cfg.alarmSoundPath
if ([string]::IsNullOrWhiteSpace($soundPath)) {
    $soundPath = Join-Path (Join-Path $env:SystemRoot 'Media') 'Alarm01.wav'
}
$player = $null
if (Test-Path $soundPath) {
    try { $player = New-Object System.Media.SoundPlayer $soundPath; $player.Load() } catch { $player = $null }
}

$script:alarming    = $false
$script:alarmStopAt = [datetime]::MinValue

function Start-TrackerAlarm {
    if (-not $cfg.alarmEnabled) { return }
    $script:alarming    = $true
    $script:alarmStopAt = (Get-Date).AddSeconds([double]$cfg.alarmSeconds)
    if ($player) { try { $player.PlayLooping() } catch { } }
    else { try { [System.Media.SystemSounds]::Exclamation.Play() } catch { } }
}

function Stop-TrackerAlarm {
    if (-not $script:alarming) { return }
    $script:alarming = $false
    if ($player) { try { $player.Stop() } catch { } }
}

# ------------------------------------------------------------------- UI ----
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Time Tracker'
$form.FormBorderStyle = 'FixedToolWindow'
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.ClientSize      = New-Object System.Drawing.Size(250, 96)
$form.BackColor       = [System.Drawing.Color]::FromArgb(24, 26, 32)
$form.StartPosition   = 'Manual'

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ([int]$cfg.windowX -ge 0 -and [int]$cfg.windowY -ge 0) {
    $form.Location = New-Object System.Drawing.Point([int]$cfg.windowX, [int]$cfg.windowY)
} else {
    $form.Location = New-Object System.Drawing.Point(($wa.Right - 270), ($wa.Bottom - 130))
}

$lblTotal           = New-Object System.Windows.Forms.Label
$lblTotal.Font      = New-Object System.Drawing.Font('Consolas', 24, [System.Drawing.FontStyle]::Bold)
$lblTotal.ForeColor = [System.Drawing.Color]::FromArgb(120, 230, 160)
$lblTotal.TextAlign = 'MiddleCenter'
$lblTotal.Dock      = 'Top'
$lblTotal.Height    = 46
$lblTotal.Text      = Format-Span ([double]$script:state.activeSeconds)

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
$lblStatus.ForeColor = [System.Drawing.Color]::Gainsboro
$lblStatus.TextAlign = 'MiddleCenter'
$lblStatus.Dock      = 'Top'
$lblStatus.Height    = 22
$lblStatus.Text      = 'starting...'

$lblSub           = New-Object System.Windows.Forms.Label
$lblSub.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
$lblSub.ForeColor = [System.Drawing.Color]::Gray
$lblSub.TextAlign = 'MiddleCenter'
$lblSub.Dock      = 'Top'
$lblSub.Height    = 20
$lblSub.Text      = ''

$form.Controls.AddRange(@($lblSub, $lblStatus, $lblTotal))

$tray         = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon    = [System.Drawing.SystemIcons]::Information
$tray.Text    = 'Time Tracker'
$tray.Visible = $true

function Show-TrackerNotification {
    param([string]$Title, [string]$Text)
    if (-not $cfg.notificationEnabled) { return }
    try { $tray.ShowBalloonTip(8000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:paused = $false
$miPause = $menu.Items.Add('Pause tracking')
$miPause.add_Click({
    $script:paused = -not $script:paused
    $miPause.Text = $(if ($script:paused) { 'Resume tracking' } else { 'Pause tracking' })
    Stop-TrackerAlarm
})
$miReset = $menu.Items.Add('Reset today')
$miReset.add_Click({
    $script:state = New-TrackerState -Now (Get-Date)
    Save-DayData -State $script:state
})
$miOpen = $menu.Items.Add('Open data folder')
$miOpen.add_Click({ Start-Process explorer.exe $dataDir })
$menu.Items.Add('-') | Out-Null
$miExit = $menu.Items.Add('Exit')
$miExit.add_Click({ $form.Close() })
$form.ContextMenuStrip = $menu
$tray.ContextMenuStrip = $menu

$script:dragging = $false
$script:dragOff  = New-Object System.Drawing.Point(0, 0)
$onDown = { param($s, $e) if ($e.Button -eq 'Left') { $script:dragging = $true; $script:dragOff = $e.Location } }
$onMove = {
    param($s, $e)
    if ($script:dragging) {
        $p = $form.Location
        $form.Location = New-Object System.Drawing.Point(($p.X + $e.X - $script:dragOff.X), ($p.Y + $e.Y - $script:dragOff.Y))
    }
}
$onUp = { $script:dragging = $false }
foreach ($c in @($form, $lblTotal, $lblStatus, $lblSub)) {
    $c.add_MouseDown($onDown); $c.add_MouseMove($onMove); $c.add_MouseUp($onUp)
}

# ----------------------------------------------------------------- loop ----
$script:lastPos  = [TTNative]::Cursor()
$script:lastTick = Get-Date
$script:lastSave = Get-Date

$colorActive = [System.Drawing.Color]::FromArgb(120, 230, 160)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int]$cfg.pollMs
$timer.add_Tick({
    $now = Get-Date

    if ($now.Date -ne [datetime]$script:state.day) {
        Save-DayData -State $script:state
        $script:state = Import-DayData -Day $now
    }

    $pos     = [TTNative]::Cursor()
    $blocked = Test-ScreenBlocked
    $moved   = Test-CursorMoved -Previous $script:lastPos -Current $pos -ThresholdPx ([int]$cfg.movementThresholdPx)

    $stepArgs = @{
        State    = $script:state
        Now      = $now
        LastTick = $script:lastTick
        Moved    = $moved
        Blocked  = $blocked
        Paused   = $script:paused
        Config   = $cfg
    }
    $step = Step-Tracker @stepArgs

    if ($step.StopAlarm)  { Stop-TrackerAlarm }
    if ($step.StartAlarm) { Start-TrackerAlarm }
    if ($step.Notify)     { Show-TrackerNotification -Title $step.NotifyTitle -Text $step.NotifyText }

    switch ($step.Status) {
        'LOCKED' {
            $lblStatus.Text      = 'LOCKED - paused'
            $lblStatus.ForeColor = [System.Drawing.Color]::CornflowerBlue
            $lblSub.Text         = 'alarm + notifications suppressed'
        }
        'PAUSED' {
            $lblStatus.Text      = 'PAUSED'
            $lblStatus.ForeColor = [System.Drawing.Color]::Goldenrod
            $lblSub.Text         = 'right-click to resume'
        }
        'MOVING' {
            $lblStatus.Text      = 'MOVING'
            $lblStatus.ForeColor = $colorActive
            $lblSub.Text         = ('idle episodes today: {0}' -f $script:state.idleEpisodes)
        }
        default {
            $lblStatus.Text      = ('IDLE {0}' -f (Format-Span ([double]$step.IdleSeconds)))
            $lblStatus.ForeColor = $(if ($script:state.alarmFired) { [System.Drawing.Color]::Tomato } else { [System.Drawing.Color]::Gainsboro })
            $lblSub.Text         = ('alarm at {0}s of stillness' -f [int]$cfg.idleSeconds)
        }
    }

    if ($script:alarming -and $now -gt $script:alarmStopAt) { Stop-TrackerAlarm }

    $lblTotal.Text = Format-Span ([double]$script:state.activeSeconds)
    $tray.Text     = ('Time Tracker - ' + $lblTotal.Text)

    $script:lastPos  = $pos
    $script:lastTick = $now

    if (($now - $script:lastSave).TotalSeconds -ge [double]$cfg.saveEverySeconds) {
        Save-DayData -State $script:state
        $script:lastSave = $now
    }
})

$form.add_FormClosing({
    $timer.Stop()
    Stop-TrackerAlarm
    Save-DayData -State $script:state
    try {
        $cfg.windowX = $form.Location.X
        $cfg.windowY = $form.Location.Y
        ([pscustomobject]$cfg | ConvertTo-Json) | Set-Content -Path $configPath -Encoding UTF8
    } catch { }
    $tray.Visible = $false
    $tray.Dispose()
})

$timer.Start()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
