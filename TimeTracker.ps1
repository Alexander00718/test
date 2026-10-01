#Requires -Version 5.1
<#
    TimeTracker.ps1
    Windows tray app: measures how long the mouse cursor is actually moving,
    alarms when it goes still for too long, stays silent on the lock screen,
    and reports the day's total when the date rolls over.

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
}
$script:cfg = Resolve-TrackerConfig -Default (Get-TrackerDefault) -Override $loaded
if ($IdleSeconds -gt 0) { $script:cfg.idleSeconds = $IdleSeconds }
if ($NoAlarm)  { $script:cfg.alarmEnabled = $false }
if ($NoNotify) { $script:cfg.notificationEnabled = $false }

function Save-TrackerConfig {
    try {
        ([pscustomobject]$script:cfg | ConvertTo-Json) | Set-Content -Path $configPath -Encoding UTF8
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            ('Could not save settings: ' + $_.Exception.Message), 'Time Tracker',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
}
if (-not (Test-Path $configPath)) { Save-TrackerConfig }

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
    if (-not $script:cfg.suppressWhenLocked) { return $false }
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
$script:player     = $null
$script:alarming   = $false
$script:alarmStopAt = [datetime]::MinValue

function Reset-AlarmSound {
    $path = [string]$script:cfg.alarmSoundPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path (Join-Path $env:SystemRoot 'Media') 'Alarm01.wav'
    }
    $script:player = $null
    if (Test-Path $path) {
        try {
            $script:player = New-Object System.Media.SoundPlayer $path
            $script:player.Load()
        } catch { $script:player = $null }
    }
}
Reset-AlarmSound

function Start-TrackerAlarm {
    if (-not $script:cfg.alarmEnabled) { return }
    $script:alarming    = $true
    $script:alarmStopAt = (Get-Date).AddSeconds([double]$script:cfg.alarmSeconds)
    if ($script:player) { try { $script:player.PlayLooping() } catch { } }
    else { try { [System.Media.SystemSounds]::Exclamation.Play() } catch { } }
}

function Stop-TrackerAlarm {
    if (-not $script:alarming) { return }
    $script:alarming = $false
    if ($script:player) { try { $script:player.Stop() } catch { } }
}

# ------------------------------------------------------------ main form ----
$accent  = [System.Drawing.Color]::FromArgb(120, 230, 160)
$bg      = [System.Drawing.Color]::FromArgb(24, 26, 32)
$panelBg = [System.Drawing.Color]::FromArgb(34, 37, 45)

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Time Tracker'
$form.FormBorderStyle = 'FixedToolWindow'
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.ClientSize      = New-Object System.Drawing.Size(300, 182)
$form.BackColor       = $bg
$form.StartPosition   = 'Manual'

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ([int]$script:cfg.windowX -ge 0 -and [int]$script:cfg.windowY -ge 0) {
    $form.Location = New-Object System.Drawing.Point([int]$script:cfg.windowX, [int]$script:cfg.windowY)
} else {
    $form.Location = New-Object System.Drawing.Point(($wa.Right - 320), ($wa.Bottom - 215))
}

$lblCaption           = New-Object System.Windows.Forms.Label
$lblCaption.Text      = 'TIME MOVING TODAY'
$lblCaption.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)
$lblCaption.ForeColor = [System.Drawing.Color]::FromArgb(130, 140, 155)
$lblCaption.TextAlign = 'MiddleCenter'
$lblCaption.Dock      = 'Top'
$lblCaption.Height    = 20

$lblTotal           = New-Object System.Windows.Forms.Label
$lblTotal.Font      = New-Object System.Drawing.Font('Consolas', 28, [System.Drawing.FontStyle]::Bold)
$lblTotal.ForeColor = $accent
$lblTotal.TextAlign = 'MiddleCenter'
$lblTotal.Dock      = 'Top'
$lblTotal.Height    = 52
$lblTotal.Text      = Format-Span ([double]$script:state.activeSeconds)

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = [System.Drawing.Color]::Gainsboro
$lblStatus.TextAlign = 'MiddleCenter'
$lblStatus.Dock      = 'Top'
$lblStatus.Height    = 24
$lblStatus.Text      = 'starting...'

$lblSub           = New-Object System.Windows.Forms.Label
$lblSub.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
$lblSub.ForeColor = [System.Drawing.Color]::Gray
$lblSub.TextAlign = 'MiddleCenter'
$lblSub.Dock      = 'Top'
$lblSub.Height    = 20
$lblSub.Text      = ''

# Button strip along the bottom.
$buttons           = New-Object System.Windows.Forms.Panel
$buttons.Dock      = 'Bottom'
$buttons.Height    = 44
$buttons.BackColor = $panelBg

function New-FlatButton {
    param([string]$Text, [int]$X, [int]$Width, [string]$Tip)
    $b                = New-Object System.Windows.Forms.Button
    $b.Text           = $Text
    $b.FlatStyle      = 'Flat'
    $b.BackColor      = [System.Drawing.Color]::FromArgb(52, 57, 69)
    $b.ForeColor      = [System.Drawing.Color]::Gainsboro
    $b.Font           = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $b.Size           = New-Object System.Drawing.Size($Width, 26)
    $b.Location       = New-Object System.Drawing.Point($X, 9)
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor         = [System.Windows.Forms.Cursors]::Hand
    if ($Tip) {
        $tt = New-Object System.Windows.Forms.ToolTip
        $tt.SetToolTip($b, $Tip)
    }
    return $b
}

$btnSettings = New-FlatButton -Text 'Settings' -X 10  -Width 88 -Tip 'Change the alarm time and other options'
$btnPause    = New-FlatButton -Text 'Pause'    -X 106 -Width 88 -Tip 'Stop counting until you resume'
$btnToday    = New-FlatButton -Text 'Today'    -X 202 -Width 88 -Tip "Show today's totals so far"
$buttons.Controls.AddRange(@($btnSettings, $btnPause, $btnToday))

$form.Controls.AddRange(@($buttons, $lblSub, $lblStatus, $lblTotal, $lblCaption))

# tray icon + notifications
$tray         = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon    = [System.Drawing.SystemIcons]::Information
$tray.Text    = 'Time Tracker'
$tray.Visible = $true

function Show-TrackerNotification {
    param([string]$Title, [string]$Text)
    if (-not $script:cfg.notificationEnabled) { return }
    try { $tray.ShowBalloonTip(8000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
}

# ------------------------------------------------------ settings dialog ----
function Show-SettingsDialog {
    $spec = Get-TrackerSettingSpec

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Time Tracker - Settings'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition   = 'CenterParent'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $bg
    $dlg.ClientSize      = New-Object System.Drawing.Size(430, (70 + ($spec.Count * 32)))
    $dlg.TopMost         = $true

    $intro           = New-Object System.Windows.Forms.Label
    $intro.Text      = 'The alarm fires after this much cursor stillness:'
    $intro.Font      = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $intro.ForeColor = [System.Drawing.Color]::FromArgb(150, 160, 175)
    $intro.Location  = New-Object System.Drawing.Point(14, 10)
    $intro.Size      = New-Object System.Drawing.Size(400, 18)
    $dlg.Controls.Add($intro)

    $editors = @{}
    $y = 34
    foreach ($s in $spec) {
        $lbl           = New-Object System.Windows.Forms.Label
        $lbl.Text      = $s.Label
        $lbl.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
        $lbl.ForeColor = [System.Drawing.Color]::Gainsboro
        $lbl.Location  = New-Object System.Drawing.Point(14, ($y + 3))
        $lbl.Size      = New-Object System.Drawing.Size(290, 20)
        $dlg.Controls.Add($lbl)

        if ($s.Kind -eq 'bool') {
            $chk          = New-Object System.Windows.Forms.CheckBox
            $chk.Checked  = [bool]$script:cfg[$s.Name]
            $chk.Location = New-Object System.Drawing.Point(312, ($y + 2))
            $chk.Size     = New-Object System.Drawing.Size(24, 20)
            $dlg.Controls.Add($chk)
            $editors[$s.Name] = $chk
        } else {
            $box           = New-Object System.Windows.Forms.TextBox
            $box.Text      = [string]$script:cfg[$s.Name]
            $box.Location  = New-Object System.Drawing.Point(312, $y)
            $box.Size      = New-Object System.Drawing.Size(70, 22)
            $box.BackColor = $panelBg
            $box.ForeColor = [System.Drawing.Color]::White
            $box.BorderStyle = 'FixedSingle'
            $dlg.Controls.Add($box)
            $editors[$s.Name] = $box

            $hint           = New-Object System.Windows.Forms.Label
            $hint.Text      = ('' + $s.Min + '-' + $s.Max)
            $hint.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
            $hint.ForeColor = [System.Drawing.Color]::FromArgb(110, 118, 132)
            $hint.Location  = New-Object System.Drawing.Point(388, ($y + 4))
            $hint.Size      = New-Object System.Drawing.Size(40, 16)
            $dlg.Controls.Add($hint)
        }
        $y += 32
    }

    $btnSave        = New-Object System.Windows.Forms.Button
    $btnSave.Text   = 'Save'
    $btnSave.Size   = New-Object System.Drawing.Size(84, 26)
    $btnSave.Location = New-Object System.Drawing.Point(242, ($y + 4))
    $btnSave.FlatStyle = 'Flat'
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(60, 120, 85)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatAppearance.BorderSize = 0

    $btnCancel      = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Size = New-Object System.Drawing.Size(84, 26)
    $btnCancel.Location = New-Object System.Drawing.Point(332, ($y + 4))
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(52, 57, 69)
    $btnCancel.ForeColor = [System.Drawing.Color]::Gainsboro
    $btnCancel.FlatAppearance.BorderSize = 0
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dlg.Controls.AddRange(@($btnSave, $btnCancel))
    $dlg.CancelButton = $btnCancel

    $btnSave.add_Click({
        # Validate everything before changing any live setting, so a bad value
        # cannot leave the config half applied.
        $pending = @{}
        foreach ($s in $spec) {
            $editor = $editors[$s.Name]
            $raw = if ($s.Kind -eq 'bool') { $editor.Checked } else { $editor.Text }
            $check = Test-TrackerSetting -Name $s.Name -Value $raw
            if (-not $check.Valid) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    $check.Message, 'Invalid setting',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            $pending[$s.Name] = $check.Value
        }
        foreach ($k in $pending.Keys) { $script:cfg[$k] = $pending[$k] }
        Save-TrackerConfig
        Reset-AlarmSound
        $script:timer.Interval = [int]$script:cfg.pollMs
        Stop-TrackerAlarm
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

# --------------------------------------------------- day summary dialog ----
function Show-DaySummary {
    param(
        [Parameter(Mandatory)][datetime]$Day,
        [double]$ActiveSeconds,
        [int]$IdleEpisodes,
        [double]$LongestIdleSeconds
    )
    $summaryArgs = @{
        Day                = $Day
        ActiveSeconds      = $ActiveSeconds
        IdleEpisodes       = $IdleEpisodes
        LongestIdleSeconds = $LongestIdleSeconds
    }
    $text = Format-DaySummary @summaryArgs
    Show-TrackerNotification -Title 'Time Tracker - day complete' -Text ('Total working time: ' + (Format-Span $ActiveSeconds))
    [void][System.Windows.Forms.MessageBox]::Show(
        $text, 'Time Tracker - that day is done',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
}

# ------------------------------------------------------------- controls ----
$script:paused = $false

$btnSettings.add_Click({ Show-SettingsDialog })

$btnPause.add_Click({
    $script:paused = -not $script:paused
    $btnPause.Text = $(if ($script:paused) { 'Resume' } else { 'Pause' })
    Stop-TrackerAlarm
})

$btnToday.add_Click({
    $todayArgs = @{
        Day                = [datetime]$script:state.day
        ActiveSeconds      = [double]$script:state.activeSeconds
        IdleEpisodes       = [int]$script:state.idleEpisodes
        LongestIdleSeconds = [double]$script:state.longestIdle
    }
    $text = Format-DaySummary @todayArgs
    [void][System.Windows.Forms.MessageBox]::Show(
        $text, 'Time Tracker - today so far',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
})

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miSettings = $menu.Items.Add('Settings...')
$miSettings.add_Click({ Show-SettingsDialog })
$miToday = $menu.Items.Add('Today so far...')
$miToday.add_Click({ $btnToday.PerformClick() })
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
$tray.add_DoubleClick({ $form.Activate() })

# drag the window by its body
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
foreach ($c in @($form, $lblTotal, $lblStatus, $lblSub, $lblCaption)) {
    $c.add_MouseDown($onDown); $c.add_MouseMove($onMove); $c.add_MouseUp($onUp)
}

# ----------------------------------------------------------------- loop ----
$script:lastPos  = [TTNative]::Cursor()
$script:lastTick = Get-Date
$script:lastSave = Get-Date

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = [int]$script:cfg.pollMs
$script:timer.add_Tick({
    $now = Get-Date

    $pos     = [TTNative]::Cursor()
    $blocked = Test-ScreenBlocked
    $moved   = Test-CursorMoved -Previous $script:lastPos -Current $pos -ThresholdPx ([int]$script:cfg.movementThresholdPx)

    $stepArgs = @{
        State    = $script:state
        Now      = $now
        LastTick = $script:lastTick
        Moved    = $moved
        Blocked  = $blocked
        Paused   = $script:paused
        Config   = $script:cfg
    }
    $step = Step-Tracker @stepArgs

    if ($step.StopAlarm)  { Stop-TrackerAlarm }
    if ($step.StartAlarm) { Start-TrackerAlarm }
    if ($step.Notify)     { Show-TrackerNotification -Title $step.NotifyTitle -Text $step.NotifyText }

    if ($step.DayEnded) {
        # Persist the finished day, report it, then begin the new one.
        Save-DayData -State $script:state
        $endedDay   = [datetime]$step.EndedDay
        $endedTotal = [double]$step.EndedActiveSeconds
        $endedIdle  = [int]$step.EndedIdleEpisodes
        $endedLong  = [double]$step.EndedLongestIdle
        $script:state    = Import-DayData -Day $now
        $script:lastPos  = $pos
        $script:lastTick = $now
        $lblTotal.Text   = Format-Span ([double]$script:state.activeSeconds)
        if ($script:cfg.showDailySummary) {
            Show-DaySummary -Day $endedDay -ActiveSeconds $endedTotal -IdleEpisodes $endedIdle -LongestIdleSeconds $endedLong
        }
        return
    }

    switch ($step.Status) {
        'LOCKED' {
            $lblStatus.Text      = 'LOCKED'
            $lblStatus.ForeColor = [System.Drawing.Color]::CornflowerBlue
            $lblSub.Text         = 'alarm and notifications suppressed'
        }
        'PAUSED' {
            $lblStatus.Text      = 'PAUSED'
            $lblStatus.ForeColor = [System.Drawing.Color]::Goldenrod
            $lblSub.Text         = 'press Resume to continue'
        }
        'MOVING' {
            $lblStatus.Text      = 'MOVING'
            $lblStatus.ForeColor = $accent
            $lblSub.Text         = ('idle episodes today: {0}' -f $script:state.idleEpisodes)
        }
        default {
            $lblStatus.Text      = ('IDLE  {0}' -f (Format-Span ([double]$step.IdleSeconds)))
            $lblStatus.ForeColor = $(if ($script:state.alarmFired) { [System.Drawing.Color]::Tomato } else { [System.Drawing.Color]::Gainsboro })
            $lblSub.Text         = ('alarm at {0}s of stillness' -f [int]$script:cfg.idleSeconds)
        }
    }

    if ($script:alarming -and $now -gt $script:alarmStopAt) { Stop-TrackerAlarm }

    $lblTotal.Text = Format-Span ([double]$script:state.activeSeconds)
    $tray.Text     = ('Time Tracker - ' + $lblTotal.Text)

    $script:lastPos  = $pos
    $script:lastTick = $now

    if (($now - $script:lastSave).TotalSeconds -ge [double]$script:cfg.saveEverySeconds) {
        Save-DayData -State $script:state
        $script:lastSave = $now
    }
})

$form.add_FormClosing({
    $script:timer.Stop()
    Stop-TrackerAlarm
    Save-DayData -State $script:state
    $script:cfg.windowX = $form.Location.X
    $script:cfg.windowY = $form.Location.Y
    Save-TrackerConfig
    $tray.Visible = $false
    $tray.Dispose()
})

$script:timer.Start()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
