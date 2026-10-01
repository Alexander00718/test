#Requires -Version 5.1
<#
    Install-DevDependencies.ps1
    Installs the modules build/Build.ps1 needs. Idempotent - safe to re-run.

    Why this does not just call Install-Module: stock Windows ships
    PowerShellGet 1.0.0.1 / PackageManagement 1.0.0.1, which bootstrap the
    NuGet provider through an interactive prompt. Under CI or any non-TTY
    shell that prompt cannot render and the install hangs forever with no
    output. Fetching the .nupkg straight from the gallery avoids the whole
    provider stack and behaves identically everywhere.
#>
[CmdletBinding()]
param(
    [string]$Scope = 'CurrentUser'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$moduleRoot = if ($Scope -eq 'CurrentUser') {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
} else {
    Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'
}
if (-not (Test-Path $moduleRoot)) { New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null }

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Install-GalleryModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][version]$MinimumVersion
    )

    $existing = Get-Module -ListAvailable -Name $Name |
        Where-Object { $_.Version -ge $MinimumVersion } |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($existing) {
        Write-Output ('ok        ' + $Name + ' ' + $existing.Version)
        return
    }

    $staging = Join-Path $env:TEMP ('devdep-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    $zip     = $staging + '.zip'
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    try {
        Write-Output ('download  ' + $Name)
        Invoke-WebRequest -Uri ('https://www.powershellgallery.com/api/v2/package/' + $Name) -OutFile $zip -UseBasicParsing
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $staging)

        $manifest = Get-ChildItem -Path $staging -Filter ($Name + '.psd1') -Recurse |
            Select-Object -First 1
        if (-not $manifest) { throw ($Name + ': no .psd1 found in the downloaded package') }

        $version = (Import-PowerShellDataFile -Path $manifest.FullName).ModuleVersion
        if (-not $version) { throw ($Name + ': manifest has no ModuleVersion') }
        if ([version]$version -lt $MinimumVersion) {
            throw ($Name + ': gallery returned ' + $version + ', need >= ' + $MinimumVersion)
        }

        # Strip NuGet packaging artefacts so the folder is a clean module.
        foreach ($junk in '_rels', 'package', '[Content_Types].xml', ($Name + '.nuspec')) {
            $p = Join-Path $staging $junk
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }

        $target = Join-Path (Join-Path $moduleRoot $Name) $version
        if (Test-Path $target) { Remove-Item $target -Recurse -Force }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Copy-Item -Path (Join-Path $staging '*') -Destination $target -Recurse -Force

        Write-Output ('installed ' + $Name + ' ' + $version)
    }
    finally {
        if (Test-Path $zip)     { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Install-GalleryModule -Name 'Pester' -MinimumVersion '5.5.0'
Install-GalleryModule -Name 'PSScriptAnalyzer' -MinimumVersion '1.22.0'

Write-Output ''
Write-Output 'Dev dependencies ready.'
