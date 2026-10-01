#Requires -Version 5.1
<#
    Build.ps1 - the single entry point used by both humans and CI.
    Whatever GitHub Actions runs, you can run identically on your desk.

        .\build\Build.ps1 -Task Lint
        .\build\Build.ps1 -Task Test
        .\build\Build.ps1 -Task Package -Version 1.0.0
        .\build\Build.ps1                      # All
#>
[CmdletBinding()]
param(
    [ValidateSet('Lint', 'Test', 'Package', 'All')]
    [string]$Task = 'All',
    [string]$Version,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$buildDir = $PSScriptRoot
if (-not $buildDir) { $buildDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root         = Split-Path -Parent $buildDir
$artifacts    = Join-Path $root 'artifacts'
$settingsFile = Join-Path $root 'PSScriptAnalyzerSettings.psd1'

if (-not (Test-Path $artifacts)) { New-Item -ItemType Directory -Path $artifacts -Force | Out-Null }

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ('=== ' + $Message) -ForegroundColor Cyan
}

function Resolve-BuildVersion {
    if ($Version) { return $Version.TrimStart('v') }
    if ($env:GITHUB_REF_NAME -and $env:GITHUB_REF_NAME -match '^v\d+\.\d+\.\d+') {
        return $env:GITHUB_REF_NAME.TrimStart('v')
    }
    $versionFile = Join-Path $root 'VERSION'
    if (Test-Path $versionFile) { return (Get-Content $versionFile -Raw).Trim() }
    return '0.0.0-dev'
}

function Invoke-Lint {
    Write-Step 'Lint (PSScriptAnalyzer)'
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        throw 'PSScriptAnalyzer is not installed. Install-Module PSScriptAnalyzer -Scope CurrentUser'
    }
    Import-Module PSScriptAnalyzer -Force

    $params = @{
        Path        = $root
        Recurse     = $true
        ErrorAction = 'Stop'
    }
    if (Test-Path $settingsFile) { $params.Settings = $settingsFile }

    $findings = @(Invoke-ScriptAnalyzer @params | Where-Object {
        $_.ScriptPath -notmatch '\\artifacts\\'
    })

    if ($findings.Count -eq 0) {
        Write-Host 'No findings.' -ForegroundColor Green
        return
    }

    $findings | Sort-Object Severity, ScriptName, Line |
        Format-Table Severity, ScriptName, Line, RuleName, Message -AutoSize -Wrap |
        Out-String -Width 200 | Write-Host

    $blocking = @($findings | Where-Object { $_.Severity -eq 'Error' })
    if ($Strict) { $blocking = $findings }

    if ($blocking.Count -gt 0) {
        throw ('Lint failed: ' + $blocking.Count + ' blocking finding(s).')
    }
    Write-Host ('Lint passed with ' + $findings.Count + ' non-blocking warning(s).') -ForegroundColor Yellow
}

function Invoke-Test {
    Write-Step 'Test (Pester)'
    $pester = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge [version]'5.0.0' } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pester) {
        throw 'Pester 5+ is not installed. Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck'
    }
    Import-Module $pester.Path -Force

    $cfg = New-PesterConfiguration
    $cfg.Run.Path        = Join-Path $root 'tests'
    $cfg.Run.PassThru    = $true
    $cfg.Output.Verbosity = 'Detailed'
    $cfg.TestResult.Enabled      = $true
    $cfg.TestResult.OutputFormat = 'NUnitXml'
    $cfg.TestResult.OutputPath   = Join-Path $artifacts 'testResults.xml'
    $cfg.CodeCoverage.Enabled      = $true
    $cfg.CodeCoverage.Path         = Join-Path (Join-Path $root 'src') 'TimeTracker.Core.psm1'
    $cfg.CodeCoverage.OutputFormat = 'JaCoCo'
    $cfg.CodeCoverage.OutputPath   = Join-Path $artifacts 'coverage.xml'

    $result = Invoke-Pester -Configuration $cfg

    Write-Host ''
    Write-Host ('Passed: ' + $result.PassedCount + '  Failed: ' + $result.FailedCount + '  Skipped: ' + $result.SkippedCount)
    if ($result.CodeCoverage) {
        $analyzed = $result.CodeCoverage.CommandsAnalyzedCount
        $executed = $result.CodeCoverage.CommandsExecutedCount
        if ($analyzed -gt 0) {
            $pct = [math]::Round(100.0 * $executed / $analyzed, 1)
            Write-Host ('Core coverage: ' + $pct + '%')
        }
    }
    if ($result.FailedCount -gt 0) {
        throw ($result.FailedCount.ToString() + ' test(s) failed.')
    }
}

function Invoke-Package {
    Write-Step 'Package'
    $v = Resolve-BuildVersion
    Write-Host ('Version: ' + $v)

    $staging = Join-Path $artifacts ('time-tracker-' + $v)
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $staging 'src') -Force | Out-Null

    $files = @(
        'TimeTracker.ps1',
        'config.json',
        'start-tracker.cmd',
        'start-tracker.vbs',
        'install-to-projects.ps1',
        'README.md',
        'CHANGELOG.md',
        'LICENSE'
    )
    foreach ($f in $files) {
        $p = Join-Path $root $f
        if (Test-Path $p) { Copy-Item $p -Destination $staging -Force }
    }
    Copy-Item (Join-Path (Join-Path $root 'src') 'TimeTracker.Core.psm1') -Destination (Join-Path $staging 'src') -Force

    ($v + "`n") | Set-Content -Path (Join-Path $staging 'VERSION') -Encoding UTF8 -NoNewline

    $zip = Join-Path $artifacts ('time-tracker-' + $v + '.zip')
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -Force

    $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
    ($hash + '  ' + (Split-Path $zip -Leaf)) |
        Set-Content -Path ($zip + '.sha256') -Encoding ASCII

    Remove-Item $staging -Recurse -Force

    Write-Host ('Artifact: ' + $zip) -ForegroundColor Green
    Write-Host ('SHA256:   ' + $hash)
}

switch ($Task) {
    'Lint'    { Invoke-Lint }
    'Test'    { Invoke-Test }
    'Package' { Invoke-Package }
    'All'     { Invoke-Lint; Invoke-Test; Invoke-Package }
}

Write-Host ''
Write-Host ('Build task "' + $Task + '" completed.') -ForegroundColor Green
