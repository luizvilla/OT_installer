<#
Automated test suite for the Phase 3/4/5 hardening work (see windows_installer_plan.md,
"Phase 3/4/5 hardening + automated test suite"):

  1. Bad-path tests: deliberately invalid -ProjectPath values (space, excessive length,
     OneDrive) against a real child-process invocation of install_owntech.ps1, asserting
     it fails fast with exit code 1 and the expected reason.
  2. Simulated network-outage tests against Invoke-BundleSeed: a local HTTP server is
     killed and (for the "recovered" case) restarted on a timer, to exercise the
     Invoke-WithRetry path without needing a real network to misbehave on command.

Usage:
    .\test_hardening.ps1

Safe to run repeatedly; each test uses a fresh temp destination and cleans up after
itself. Does not touch D:\owntech, D:\.platformio_core, or any installed software --
this only exercises Test-ProjectPath and Invoke-BundleSeed in isolation, never the full
install_owntech.ps1 pipeline end to end.
#>

$ErrorActionPreference = 'Continue'
$scriptDir = $PSScriptRoot
$installScript = Join-Path $scriptDir 'install_owntech.ps1'

$results = @()
function Record-Result($Name, $Passed, $Detail) {
    $script:results += [pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail }
    $status = if ($Passed) { '[PASS]' } else { '[FAIL]' }
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host "$status $Name -- $Detail" -ForegroundColor $color
}

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host " Hardening test suite" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan

# ----------------------------------------------------------------------------
# Group 1: Bad-path tests (deliberately wrong -ProjectPath values)
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "== Group 1: Bad-path validation ==" -ForegroundColor Cyan

function Test-BadPath($Name, $Path, $ExpectedReasonPattern) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript `
        -ProjectPath $Path -NonInteractive -SkipBuildTest 2>&1 | Out-String
    $exit = $LASTEXITCODE
    $reasonMatched = $out -match $ExpectedReasonPattern
    $passed = ($exit -eq 1) -and $reasonMatched
    $detail = "exit=$exit (want 1), reason-matched=$reasonMatched"
    Record-Result $Name $passed $detail
    if (-not $passed) {
        Write-Host "  --- tail of output ---" -ForegroundColor Yellow
        Write-Host ($out -split "`n" | Select-Object -Last 15 | Out-String)
    }
}

Test-BadPath -Name 'Path with a space' -Path 'D:\owntech test dir' -ExpectedReasonPattern 'contains spaces'

$longPath = 'D:\' + ('a' * 260)
Test-BadPath -Name 'Path over 256 chars' -Path $longPath -ExpectedReasonPattern 'characters; must be under 256'

Test-BadPath -Name 'Path containing OneDrive' -Path 'D:\OneDrive\owntech' -ExpectedReasonPattern 'OneDrive-synced folder'

# ----------------------------------------------------------------------------
# Group 2: Simulated network-outage tests against Invoke-BundleSeed
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "== Group 2: Simulated network outages ==" -ForegroundColor Cyan

# Extract the function-only portion of install_owntech.ps1 (everything before
# "# Main") so it can be dot-sourced without triggering the real install run.
$lines = Get-Content $installScript
$mainIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -eq '# Main') { $mainIdx = $i; break }
}
if ($mainIdx -lt 0) {
    Record-Result 'Network outage tests' $false "Could not locate '# Main' marker in install_owntech.ps1 to isolate functions -- skipping this group."
} else {
    $funcOnlyPath = Join-Path $env:TEMP 'test_hardening_functions_only.ps1'
    $lines[0..($mainIdx - 3)] | Set-Content -Path $funcOnlyPath -Encoding utf8
    . $funcOnlyPath

    $serveDir = Join-Path $env:TEMP 'test_hardening_serve'
    New-Item -ItemType Directory -Path $serveDir -Force -ErrorAction SilentlyContinue | Out-Null
    $dummyContentDir = Join-Path $serveDir 'content'
    New-Item -ItemType Directory -Path $dummyContentDir -Force -ErrorAction SilentlyContinue | Out-Null
    'dummy bundle content for hardening test' | Set-Content -Path (Join-Path $dummyContentDir 'marker.txt')
    $dummyZip = Join-Path $serveDir 'dummy_bundle.zip'
    Remove-Item $dummyZip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $dummyContentDir '*') -DestinationPath $dummyZip -Force
    # Invoke-BundleSeed's Expand-Archive/7za target is $CoreDir directly, and it
    # checks for 'packages'/'platforms' subfolders to decide idempotency -- a
    # generic dummy zip doesn't produce those, which is fine here since these
    # tests only care whether the download+extract mechanics succeed, not
    # about real PlatformIO package content.
    $dummyHash = (Get-FileHash -Path $dummyZip -Algorithm SHA256).Hash

    $port = 8712
    $serverArgs = @('-m', 'http.server', "$port")

    function Start-TestServer {
        return Start-Process -FilePath python -ArgumentList $serverArgs -WorkingDirectory $serveDir -WindowStyle Hidden -PassThru
    }
    function Stop-TestServer($proc) {
        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Test A: transient outage, recovered by retry ---
    $coreDirA = Join-Path $env:TEMP 'test_hardening_coredir_a'
    Remove-Item $coreDirA -Recurse -Force -ErrorAction SilentlyContinue

    $server = Start-TestServer
    Start-Sleep -Milliseconds 800
    Stop-TestServer $server
    # Server is now down. Schedule a restart to land inside Invoke-WithRetry's
    # first backoff window (2s) so the retry -- not a fresh call -- is what
    # succeeds. The job writes the new process's PID to a file so the main
    # script can clean it up precisely afterward, instead of guessing.
    $restartPidFile = Join-Path $env:TEMP 'test_hardening_restart.pid'
    Remove-Item $restartPidFile -Force -ErrorAction SilentlyContinue
    $restartJob = Start-Job -ScriptBlock {
        param($py, $procArgs, $dir, $delayMs, $pidFile)
        Start-Sleep -Milliseconds $delayMs
        $p = Start-Process -FilePath $py -ArgumentList $procArgs -WorkingDirectory $dir -WindowStyle Hidden -PassThru
        $p.Id | Out-File $pidFile
    } -ArgumentList 'python', $serverArgs, $serveDir, 1200, $restartPidFile

    $t0 = Get-Date
    $threw = $false
    try {
        Invoke-BundleSeed -BundleUrl "http://localhost:$port/dummy_bundle.zip" -BundleSha256 $dummyHash -CoreDir $coreDirA
    } catch {
        $threw = $true
    }
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    Wait-Job $restartJob -Timeout 10 | Out-Null
    Remove-Job $restartJob -Force -ErrorAction SilentlyContinue

    # Success signal: no exception escaped, and the zip was actually reached
    # (its marker file extracted) -- not just a silent no-op.
    $markerExtracted = Test-Path (Join-Path $coreDirA 'marker.txt')
    $passedA = (-not $threw) -and $markerExtracted
    Record-Result 'Transient outage recovered by retry' $passedA "threw=$threw, marker-extracted=$markerExtracted, elapsed=$([math]::Round($elapsed,1))s"

    if (Test-Path $restartPidFile) {
        $restartedPid = [int](Get-Content $restartPidFile -Raw).Trim()
        Stop-Process -Id $restartedPid -Force -ErrorAction SilentlyContinue
        Remove-Item $restartPidFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $coreDirA -Recurse -Force -ErrorAction SilentlyContinue

    # --- Test B: sustained outage, retries exhausted, graceful fallback ---
    $coreDirB = Join-Path $env:TEMP 'test_hardening_coredir_b'
    Remove-Item $coreDirB -Recurse -Force -ErrorAction SilentlyContinue
    # No server running at all for this one -- every attempt fails.

    $t0 = Get-Date
    $threwB = $false
    try {
        Invoke-BundleSeed -BundleUrl "http://localhost:$port/dummy_bundle.zip" -BundleSha256 $dummyHash -CoreDir $coreDirB
    } catch {
        $threwB = $true
    }
    $elapsedB = ((Get-Date) - $t0).TotalSeconds
    $noPartialState = -not (Test-Path (Join-Path $coreDirB 'marker.txt'))
    # 3 attempts with 2s/4s backoff between them should take at least ~6s if
    # retries actually happened, not failed instantly on the first try.
    $retriesHappened = $elapsedB -ge 5
    $passedB = (-not $threwB) -and $noPartialState -and $retriesHappened
    Record-Result 'Sustained outage fails gracefully' $passedB "threw=$threwB, no-partial-state=$noPartialState, retries-happened=$retriesHappened, elapsed=$([math]::Round($elapsedB,1))s"

    Remove-Item $coreDirB -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $serveDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $funcOnlyPath -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan
$results | Format-Table Name, Passed, Detail -AutoSize
$failCount = ($results | Where-Object { -not $_.Passed }).Count
Write-Host "$($results.Count) tests, $failCount failed." -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })
exit $(if ($failCount -eq 0) { 0 } else { 1 })
