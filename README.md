# Time Tracker

[![CI](https://github.com/Alexander00718/test/actions/workflows/ci.yml/badge.svg)](https://github.com/Alexander00718/test/actions/workflows/ci.yml)
[![Release](https://github.com/Alexander00718/test/actions/workflows/release.yml/badge.svg)](https://github.com/Alexander00718/test/actions/workflows/release.yml)

A tiny Windows tray app that measures **how long your mouse cursor is actually
moving**, nags you when you go still, and keeps quiet while the PC is locked.

Zero runtime dependencies - Windows PowerShell 5.1 + WinForms. No install,
no Python, no npm.

## What it does

| Requirement | How it works |
|---|---|
| Measure time the cursor moves | Polls `GetCursorPos` every 250 ms; every tick where the cursor moved at least 2 px adds to the active total |
| Alarm + notification after 2 min of no movement | Looping `Alarm01.wav` plus a Windows toast, fired once per idle episode |
| Nothing fires on the lock screen | `OpenInputDesktop` probe + screen-saver check + `LogonUI` process check; while blocked the timer pauses and both alarm and toast are suppressed |
| Always display the running total | Always-on-top 250x96 window, draggable anywhere, plus the total in the tray tooltip |

The alarm stops by itself the moment you move the cursor again (or after
`alarmSeconds`, whichever comes first). Unlocking never triggers an instant
alarm - the idle clock is re-armed while the screen is blocked.

## Layout

```
TimeTracker.ps1              GUI shell: Win32 probes, sound, pixels
src/TimeTracker.Core.psm1    all decision logic - pure, clock-free, tested
tests/                       Pester 5 unit + syntax tests
build/Build.ps1              lint / test / package, used by humans and CI
.github/workflows/           CI on every push, Release on every tag
config.json                  settings
start-tracker.vbs            silent launcher (recommended)
start-tracker.cmd            launcher with a brief console flash
install-to-projects.ps1      copy to C:\projects + optional autostart
docs/CICD.md                 pipeline documentation
```

Time is injected into every core function rather than read from `Get-Date`,
which is why the 2-minute rule can be verified in milliseconds instead of by
sitting still for two minutes.

## Run it

```powershell
wscript .\start-tracker.vbs                                              # silent
.\start-tracker.cmd                                                      # with console flash
powershell -NoProfile -ExecutionPolicy Bypass -File .\TimeTracker.ps1 -IdleSeconds 60
```

Right-click the window or the tray icon for **Pause / Resume**, **Reset today**,
**Open data folder**, **Exit**.

## Install to C:\projects and autostart

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-to-projects.ps1 -AutoStart
```

The installer verifies the copied core module imports before declaring success.

## Configuration - `config.json`

| Key | Default | Meaning |
|---|---|---|
| `idleSeconds` | `120` | Stillness before the alarm fires |
| `pollMs` | `250` | Cursor sampling interval, and the resolution of the total |
| `movementThresholdPx` | `2` | Ignore jitter smaller than this |
| `alarmEnabled` | `true` | Play the sound |
| `alarmSeconds` | `15` | Max alarm duration |
| `alarmSoundPath` | `""` | Custom `.wav`; empty uses `%SystemRoot%\Media\Alarm01.wav` |
| `notificationEnabled` | `true` | Show the toast |
| `suppressWhenLocked` | `true` | Pause everything on the lock screen / screen saver |
| `saveEverySeconds` | `30` | Autosave interval |
| `windowX`, `windowY` | `-1` | Window position, saved on exit; `-1` means bottom-right |

CLI flags `-IdleSeconds`, `-NoAlarm`, `-NoNotify` override the file.
Unknown keys in `config.json` are ignored rather than trusted.

## Data

One JSON file per day in `data\`:

```json
{
  "date": "2026-09-29",
  "activeSeconds": 4821.5,
  "activeFormatted": "01:20:21",
  "idleEpisodes": 7,
  "longestIdleSeconds": 942.3,
  "lastSaved": "2026-09-29T18:14:02"
}
```

Totals survive restarts and roll over automatically at midnight.

## Development

One-time setup. This uses the same script CI uses, so a green local run means
the same dependency versions were exercised:

```powershell
.\build\Install-DevDependencies.ps1
```

It fetches Pester and PSScriptAnalyzer straight from the PowerShell Gallery
rather than calling `Install-Module`, because stock Windows ships
PowerShellGet 1.0.0.1, which blocks forever on an invisible NuGet-provider
prompt when no terminal is attached.

### Run the CI checks locally

Every gate CI enforces, in the order CI runs it:

```powershell
.\build\Build.ps1 -Task Lint -Strict    # job 1: PSScriptAnalyzer, warnings fail
.\build\Build.ps1 -Task Test            # job 2: Pester + coverage
.\build\Build.ps1 -Task Package         # job 3: zip + SHA256

.\build\Build.ps1                       # all three, lint non-strict
```

There is no hidden pipeline logic: the workflows call this one script.

### Pipeline

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yml` | pull requests, pushes to `main` | **Lint** and **Test** run concurrently; **Build** runs only if both pass |
| `cd.yml` | after CI succeeds on `main` | Dormant. Reports which deployment configuration is missing; activates when a `DEPLOY_TARGET` repository variable is set |
| `release.yml` | tags matching `v*.*.*` | Re-runs every gate, then publishes a GitHub Release with the zip and its SHA256 |

Runner is `windows-latest` with `shell: powershell`, which is Windows
PowerShell 5.1 - the engine the app targets. CI cannot pass on a runtime the
users do not have.

`permissions: contents: read` applies to CI and CD. Only `release.yml`
requests `contents: write`, and only to create the Release.

See [docs/CICD.md](docs/CICD.md) for the full pipeline description, including
an honest list of what CI does and does not prove.
## Known limits

- **Cursor movement only.** Typing without touching the mouse counts as idle -
  that is what was asked for. Counting keyboard activity means switching the
  poll to `GetLastInputInfo`.
- Remote-desktop sessions report a cursor position even when nobody is there.
- The lock probe is a heuristic triple-check; reliable in practice, but not a
  documented lock API.
- The script is unsigned, hence `-ExecutionPolicy Bypass` in the launchers.
