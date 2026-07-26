<#
Reset script for OwnTech environment-setup dry runs.

Uninstalls Git, CMake, VS Code (via winget) and removes leftover config/cache
folders (PlatformIO core -- including a redirected core dir from a low-disk
run of install_owntech.ps1, VS Code settings, gitconfig, pip cache) so the
next install pass starts from a genuinely clean machine.

Python is NOT uninstalled by default -- versions vary and you don't want this
script guessing which Python install to remove -- unless -IncludePython is
passed, in which case the winget-managed Python.Python.3.12 package (the one
install_owntech.ps1 installs) is uninstalled specifically.

Usage (elevated PowerShell):
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    .\reset_environment.ps1
    .\reset_environment.ps1 -ProjectPath D:\owntech -IncludePython -NonInteractive

Only run this on the disposable test machine used for recording/timing runs,
not your everyday dev machine -- it uninstalls real tooling.
#>

[CmdletBinding()]
param(
    [string]$ProjectPath,
    [switch]$IncludePython,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator. The winget packages this script uninstalls (Git, CMake, VS Code, optionally Python) have installed fine at user scope in testing without elevation, but if any of them were installed machine-wide on this system, their uninstall may silently fail below -- rerun elevated if 'winget list' still shows them afterward."
}

$appsToRemove = @(
    'Git.Git',
    'Kitware.CMake',
    'Microsoft.VisualStudioCode'
)
if ($IncludePython) {
    $appsToRemove += 'Python.Python.3.12'
}

$foldersToDelete = @(
    "$env:USERPROFILE\.platformio",
    "$env:APPDATA\Code",
    "$env:USERPROFILE\.vscode",
    "$env:LOCALAPPDATA\pip"
)

# install_owntech.ps1 redirects PlatformIO's core dir off the system drive
# when it's low on space (Set-PlatformIOCoreDir) and persists it as a User
# env var -- the default $env:USERPROFILE\.platformio above won't exist in
# that case, so pick up the real location from the registry instead.
$redirectedCoreDir = [System.Environment]::GetEnvironmentVariable('PLATFORMIO_CORE_DIR', 'User')
if ($redirectedCoreDir) {
    $foldersToDelete += $redirectedCoreDir
}

Write-Host "== OwnTech environment reset ==" -ForegroundColor Cyan
Write-Host "This will uninstall: $($appsToRemove -join ', ')"
Write-Host "And delete these folders if present:"
$foldersToDelete | ForEach-Object { Write-Host "  $_" }
Write-Host "  $env:USERPROFILE\.gitconfig"
if ($redirectedCoreDir) {
    Write-Host "And clear the PLATFORMIO_CORE_DIR user environment variable ($redirectedCoreDir)."
}
Write-Host ""

if (-not $ProjectPath -and -not $NonInteractive) {
    $ProjectPath = Read-Host "Path to your cloned project folder to also delete (leave blank to skip)"
}

if (-not $NonInteractive) {
    $confirm = Read-Host "Type YES to continue"
    if ($confirm -ne 'YES') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warning "winget not found. Install 'App Installer' from the Microsoft Store, or uninstall these apps manually from Settings > Apps."
} else {
    foreach ($id in $appsToRemove) {
        Write-Host "Uninstalling $id..." -ForegroundColor Cyan
        winget uninstall --id $id -e --silent --accept-source-agreements
    }

    if (-not $IncludePython) {
        Write-Host ""
        Write-Host "Checking for Python 3.x installs (not auto-removed; pass -IncludePython to include it)..." -ForegroundColor Cyan
        $pythonLines = winget list --name Python 2>$null | Select-String 'Python 3'
        if ($pythonLines) {
            Write-Host "Found the following -- remove manually, or re-run with -IncludePython, for a clean Python re-install too:"
            $pythonLines | ForEach-Object { Write-Host "  $_" }
            Write-Host "Example: winget uninstall --id Python.Python.3.12 -e"
        } else {
            Write-Host "No winget-managed Python 3.x install found."
        }
    }
}

Write-Host ""
foreach ($folder in $foldersToDelete) {
    if (Test-Path $folder) {
        Write-Host "Deleting $folder..." -ForegroundColor Cyan
        Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($redirectedCoreDir) {
    Write-Host "Clearing PLATFORMIO_CORE_DIR user environment variable..." -ForegroundColor Cyan
    [System.Environment]::SetEnvironmentVariable('PLATFORMIO_CORE_DIR', $null, 'User')
    $env:PLATFORMIO_CORE_DIR = $null
}

$gitconfig = "$env:USERPROFILE\.gitconfig"
if (Test-Path $gitconfig) {
    Write-Host "Deleting $gitconfig..." -ForegroundColor Cyan
    Remove-Item -Path $gitconfig -Force -ErrorAction SilentlyContinue
}

if ($ProjectPath -and (Test-Path $ProjectPath)) {
    Write-Host "Deleting project folder $ProjectPath..." -ForegroundColor Cyan
    Remove-Item -Path $ProjectPath -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "== PATH entries worth a manual glance ==" -ForegroundColor Cyan
$env:Path -split ';' | Where-Object { $_ -match 'git|python|cmake|vs ?code' -and $_ -ne '' }

Write-Host ""
Write-Host "Done. Reboot before your next timed/recording pass so PATH changes and file locks fully clear." -ForegroundColor Green
