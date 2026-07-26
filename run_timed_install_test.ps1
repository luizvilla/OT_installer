<#
Resets the machine to a clean state, then runs install_owntech.ps1 timed, and
appends the result to a CSV history -- so you can compare install time across
runs (e.g. before/after publishing a -BundleUrl bundle, or after a real
regression) instead of eyeballing a single run's printed time.

install_owntech.ps1 already prints its own total ("Total install time: ...")
for any single run; this wrapper is for the reset+reinstall *cycle*, and for
building up a comparable history across multiple cycles.

Usage (elevated PowerShell):
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    .\run_timed_install_test.ps1 -ProjectPath D:\owntech
    .\run_timed_install_test.ps1 -ProjectPath D:\owntech -IncludePython
    .\run_timed_install_test.ps1 -ProjectPath D:\owntech -BundleUrl <url> -BundleSha256 <hash> -Label "with-bundle"

Only run this on a disposable test machine -- see reset_environment.ps1's own
warning. A reboot between cycles is recommended (stale PATH entries or file
locks left over from the uninstall can skew timing) but not enforced here --
this script doesn't reboot for you, so back-to-back cycles without a reboot
in between should be treated as slightly less reliable timing data.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,
    [switch]$IncludePython,
    [string]$BundleUrl,
    [string]$BundleSha256,
    [string]$Label = '',
    [string]$HistoryCsv
)

$ErrorActionPreference = 'Continue'
$scriptDir = $PSScriptRoot
if (-not $HistoryCsv) {
    $HistoryCsv = Join-Path $scriptDir 'install_timing_history.csv'
}

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host " Timed install test cycle" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan

# --- Step 1: Reset ---
Write-Host ""
Write-Host "== Step 1/2: Reset environment ==" -ForegroundColor Cyan
$resetStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
& (Join-Path $scriptDir 'reset_environment.ps1') -ProjectPath $ProjectPath -IncludePython:$IncludePython -NonInteractive
$resetExit = $LASTEXITCODE
$resetStopwatch.Stop()
Write-Host ""
Write-Host "Reset step took $($resetStopwatch.Elapsed.ToString('hh\:mm\:ss')) (exit code $resetExit)." -ForegroundColor Cyan

# --- Step 2: Timed install ---
Write-Host ""
Write-Host "== Step 2/2: Timed install ==" -ForegroundColor Cyan
$logPath = Join-Path $scriptDir "install_timing_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$installStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Hashtable splatting binds by name; array splatting binds positionally and
# would NOT recognize '-ProjectPath' as a parameter name here -- it would be
# passed as a literal positional string value instead.
$installArgs = @{
    ProjectPath    = $ProjectPath
    NonInteractive = $true
}
if ($BundleUrl) { $installArgs['BundleUrl'] = $BundleUrl }
if ($BundleSha256) { $installArgs['BundleSha256'] = $BundleSha256 }

& (Join-Path $scriptDir 'install_owntech.ps1') @installArgs *> $logPath
$installExit = $LASTEXITCODE
$installStopwatch.Stop()
$installElapsed = $installStopwatch.Elapsed.ToString('hh\:mm\:ss')

Write-Host ""
if ($installExit -eq 0) {
    Write-Host "Install succeeded in $installElapsed." -ForegroundColor Green
} else {
    Write-Host "Install FAILED (exit code $installExit) after $installElapsed. Log: $logPath" -ForegroundColor Red
    Write-Host "Last 15 lines:" -ForegroundColor Yellow
    Get-Content $logPath -Tail 15
}

# --- Record history ---
$row = [ordered]@{
    Timestamp     = (Get-Date -Format 'o')
    Label         = $Label
    ProjectPath   = $ProjectPath
    IncludePython = [bool]$IncludePython
    BundleUsed    = [bool]$BundleUrl
    ResetExit     = $resetExit
    InstallExit   = $installExit
    InstallTime   = $installElapsed
    LogFile       = $logPath
}

[PSCustomObject]$row | Export-Csv -Path $HistoryCsv -Append -NoTypeInformation -Force

Write-Host ""
Write-Host "Recorded to $HistoryCsv" -ForegroundColor Cyan
if (Test-Path $HistoryCsv) {
    Write-Host ""
    Write-Host "History so far:" -ForegroundColor Cyan
    Import-Csv $HistoryCsv | Format-Table Timestamp, Label, BundleUsed, InstallExit, InstallTime -AutoSize
}
