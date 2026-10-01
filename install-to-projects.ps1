<#
    install-to-projects.ps1
    Copies this project to C:\projects\time-tracker and (optionally) adds it
    to your per-user Startup folder so it launches at logon.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\install-to-projects.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File .\install-to-projects.ps1 -AutoStart
#>
[CmdletBinding()]
param(
    [string]$Destination = 'C:\projects\time-tracker',
    [switch]$AutoStart
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
if (-not $src) { $src = Split-Path -Parent $MyInvocation.MyCommand.Path }

if (-not (Test-Path $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Write-Host ('created ' + $Destination)
}

# Runtime files. src/TimeTracker.Core.psm1 is NOT optional - the GUI imports
# it on startup and will not launch without it.
$rootFiles = @(
    'TimeTracker.ps1',
    'config.json',
    'start-tracker.cmd',
    'start-tracker.vbs',
    'install-to-projects.ps1',
    'README.md',
    'CHANGELOG.md',
    'VERSION'
)

foreach ($f in $rootFiles) {
    $p = Join-Path $src $f
    if (Test-Path $p) {
        Copy-Item $p -Destination $Destination -Force
        Write-Host ('copied  ' + $f)
    }
}

$srcDir = Join-Path $src 'src'
$dstDir = Join-Path $Destination 'src'
if (-not (Test-Path $srcDir)) {
    throw "Missing src\TimeTracker.Core.psm1 next to this script - refusing to install a broken copy."
}
if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
Copy-Item (Join-Path $srcDir '*.psm1') -Destination $dstDir -Force
Write-Host 'copied  src\TimeTracker.Core.psm1'

# Verify the installed copy can at least be parsed and imported.
$installedCore = Join-Path $dstDir 'TimeTracker.Core.psm1'
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($installedCore, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
    throw ('Installed core module has parse errors: ' + ($errors[0].Message))
}
Import-Module $installedCore -Force
if (-not (Get-Command Step-Tracker -ErrorAction SilentlyContinue)) {
    throw 'Installed core module did not export Step-Tracker.'
}
Write-Host 'verified core module imports cleanly' -ForegroundColor Green

if ($AutoStart) {
    $startup = [Environment]::GetFolderPath('Startup')
    $link    = Join-Path $startup 'Time Tracker.lnk'
    $shell   = New-Object -ComObject WScript.Shell
    $sc      = $shell.CreateShortcut($link)
    $sc.TargetPath       = Join-Path $Destination 'start-tracker.vbs'
    $sc.WorkingDirectory = $Destination
    $sc.Description      = 'Cursor movement time tracker'
    $sc.Save()
    Write-Host ('autostart shortcut: ' + $link)
}

Write-Host ''
Write-Host 'Done. Launch it with:'
Write-Host ('  wscript "' + (Join-Path $Destination 'start-tracker.vbs') + '"')
