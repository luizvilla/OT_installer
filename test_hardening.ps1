<#
Automated test suite for the Phase 3/4/5 hardening work (see windows_installer_plan.md,
"Phase 3/4/5 hardening + automated test suite"):

  1. Bad-path tests: deliberately invalid -ProjectPath values (space, excessive length,
     OneDrive) against a real child-process invocation of install_owntech.ps1, asserting
     it fails fast with exit code 1 and the expected reason.
  2. Simulated network-outage tests against Invoke-BundleSeed: a local HTTP server is
     killed and (for the "recovered" case) restarted on a timer, to exercise the
     Invoke-WithRetry path without needing a real network to misbehave on command.
  3. winget retry tests against Install-WingetApp: a fake winget.cmd placed ahead of
     the real one on PATH, controllable to fail a set number of times before
     succeeding, since real winget can't be pointed at a controllable local stand-in
     the way HTTP downloads can.
  4. Per-phase invocation test: runs all 11 -RunPhase values as separate child
     processes in order (mirroring how a wizard's [Code] section would drive them via
     Exec) against an already-configured D:\owntech, then compares the resulting
     install-state file against one produced by a normal default (no -RunPhase) run --
     proving the per-phase mechanism reproduces a full run's result, not just that
     each phase runs without error in isolation.

Usage:
    .\test_hardening.ps1

Safe to run repeatedly; Groups 1-3 use fresh temp destinations and clean up after
themselves, touching neither D:\owntech nor D:\.platformio_core. Group 4 is the
exception -- it runs the real install_owntech.ps1 pipeline (twice, once per-phase and
once as a full run) against the actual D:\owntech checkout, relying on every step
being idempotent on an already-configured machine; it skips itself with a clear
message if D:\owntech isn't present rather than trying to set one up.
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
}

# ----------------------------------------------------------------------------
# Group 3: winget retry-with-backoff (Install-WingetApp)
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "== Group 3: winget install retry ==" -ForegroundColor Cyan

if ($mainIdx -lt 0) {
    Record-Result 'winget retry tests' $false "Functions were not isolated (see Group 2 failure above) -- skipping this group."
} else {
    # A fake winget.cmd, placed ahead of the real winget on PATH for this
    # process only, so retry behavior can be tested without needing a real
    # network to misbehave on command and without touching real software.
    # Controlled via env vars read by the .cmd itself: FAKE_WINGET_FAIL_UNTIL
    # (fail on attempts before this number, succeed from then on) and
    # FAKE_WINGET_COUNTER_FILE / FAKE_WINGET_MARKER_FILE (per-test state,
    # since each invocation is a separate process with no shared memory).
    $fakeWingetDir = Join-Path $env:TEMP 'test_hardening_fake_winget'
    New-Item -ItemType Directory -Path $fakeWingetDir -Force -ErrorAction SilentlyContinue | Out-Null
    $fakeWingetCmd = Join-Path $fakeWingetDir 'winget.cmd'
    @'
@echo off
setlocal enabledelayedexpansion
set /a attempt=0
if exist "%FAKE_WINGET_COUNTER_FILE%" (
    set /p attempt=<"%FAKE_WINGET_COUNTER_FILE%"
)
set /a attempt+=1
echo %attempt% > "%FAKE_WINGET_COUNTER_FILE%"

if %attempt% LSS %FAKE_WINGET_FAIL_UNTIL% (
    echo FAKE WINGET: simulated failure on attempt %attempt%
    exit /b 1
) else (
    echo FAKE WINGET: simulated success on attempt %attempt%
    echo installed> "%FAKE_WINGET_MARKER_FILE%"
    exit /b 0
)
'@ | Set-Content -Path $fakeWingetCmd -Encoding ascii

    $originalPath = $env:Path

    # --- Test C: transient winget failure, recovered by retry ---
    $counterFileC = Join-Path $env:TEMP 'test_hardening_winget_counter_c.txt'
    $markerFileC = Join-Path $env:TEMP 'test_hardening_winget_marker_c.txt'
    Remove-Item $counterFileC, $markerFileC -Force -ErrorAction SilentlyContinue
    $env:Path = "$fakeWingetDir;$originalPath"
    $env:FAKE_WINGET_FAIL_UNTIL = '2'   # fails attempt 1, succeeds attempt 2
    $env:FAKE_WINGET_COUNTER_FILE = $counterFileC
    $env:FAKE_WINGET_MARKER_FILE = $markerFileC

    $t0 = Get-Date
    $threwC = $false
    try {
        Install-WingetApp -Id 'Fake.RecoversOnRetry' -DisplayName 'FakeAppRecover' -VerifyCommand 'fakecmd' `
            -VerifyScriptBlock { Test-Path $env:FAKE_WINGET_MARKER_FILE }.GetNewClosure()
    } catch {
        $threwC = $true
    }
    $elapsedC = ((Get-Date) - $t0).TotalSeconds
    $attemptsC = if (Test-Path $counterFileC) { [int](Get-Content $counterFileC -Raw).Trim() } else { 0 }
    $env:Path = $originalPath

    # Success signal: didn't throw/exit, the fake winget's marker file exists
    # (meaning it actually reported success), and it took exactly 2 attempts
    # (not 1 -- proving the retry, not a lucky first try; not 3 -- proving it
    # stopped retrying once recovered).
    $passedC = (-not $threwC) -and (Test-Path $markerFileC) -and ($attemptsC -eq 2)
    Record-Result 'winget transient failure recovered by retry' $passedC "threw=$threwC, marker-exists=$(Test-Path $markerFileC), attempts=$attemptsC, elapsed=$([math]::Round($elapsedC,1))s"

    # --- Test D: sustained winget failure, retries exhausted, fails safely ---
    # Install-WingetApp calls Stop-Install (exit 1) once retries are exhausted
    # and verification still fails -- exactly like the bad-path tests in
    # Group 1, this must run as a real child process so that exit doesn't
    # kill this test runner too.
    $counterFileD = Join-Path $env:TEMP 'test_hardening_winget_counter_d.txt'
    $markerFileD = Join-Path $env:TEMP 'test_hardening_winget_marker_d.txt'
    Remove-Item $counterFileD, $markerFileD -Force -ErrorAction SilentlyContinue

    $childScript = Join-Path $env:TEMP 'test_hardening_winget_child.ps1'
    @"
. '$funcOnlyPath'
`$ErrorActionPreference = 'Continue'
Install-WingetApp -Id 'Fake.AlwaysFails' -DisplayName 'FakeAppFail' -VerifyCommand 'fakecmd' ``
    -VerifyScriptBlock { Test-Path `$env:FAKE_WINGET_MARKER_FILE }
"@ | Set-Content -Path $childScript -Encoding utf8

    $t0 = Get-Date
    $env:Path = "$fakeWingetDir;$originalPath"
    $env:FAKE_WINGET_FAIL_UNTIL = '999'   # never succeeds
    $env:FAKE_WINGET_COUNTER_FILE = $counterFileD
    $env:FAKE_WINGET_MARKER_FILE = $markerFileD
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $childScript 2>&1 | Out-String
    $childExit = $LASTEXITCODE
    $elapsedD = ((Get-Date) - $t0).TotalSeconds
    $env:Path = $originalPath

    $attemptsD = if (Test-Path $counterFileD) { [int](Get-Content $counterFileD -Raw).Trim() } else { 0 }
    $reasonMatchedD = $out -match 'install failed \(winget exit code 1\) after retries'
    $retriesHappenedD = $elapsedD -ge 5
    $passedD = ($childExit -eq 1) -and ($attemptsD -eq 3) -and $reasonMatchedD -and $retriesHappenedD
    Record-Result 'winget sustained failure exhausts retries and fails safely' $passedD `
        "exit=$childExit (want 1), attempts=$attemptsD (want 3), reason-matched=$reasonMatchedD, retries-happened=$retriesHappenedD, elapsed=$([math]::Round($elapsedD,1))s"
    if (-not $passedD) {
        Write-Host "  --- tail of output ---" -ForegroundColor Yellow
        Write-Host ($out -split "`n" | Select-Object -Last 15 | Out-String)
    }

    Remove-Item $counterFileC, $markerFileC, $counterFileD, $markerFileD, $childScript -Force -ErrorAction SilentlyContinue
    Remove-Item $fakeWingetDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\FAKE_WINGET_FAIL_UNTIL, Env:\FAKE_WINGET_COUNTER_FILE, Env:\FAKE_WINGET_MARKER_FILE -ErrorAction SilentlyContinue
}

if ($mainIdx -ge 0) {
    Remove-Item $funcOnlyPath -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Group 4: -RunPhase sequence reproduces a full run's result
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "== Group 4: per-phase invocation vs. a full run ==" -ForegroundColor Cyan

$verifyProjectPath = 'D:\owntech'
if (-not (Test-Path (Join-Path $verifyProjectPath '.git'))) {
    Record-Result 'Per-phase sequence matches a full run' $false `
        "Skipped -- $verifyProjectPath isn't a configured OwnTech checkout on this machine to compare against."
} else {
    # Both sides run against the same already-configured project, so every
    # step takes the idempotent skip path on both sides -- this proves the
    # per-phase *mechanism* (state correctly flows across real process
    # boundaries, every phase's own exit code is 0) reproduces a full run's
    # result, not that a fresh install works (that's what the real timed
    # cycle in windows_installer_plan.md's "Step 5" already verified).
    $orderedPhases = @('preflight', 'git', 'python', 'cmake', 'vscode', 'extensions', 'clone', 'bundle', 'bootstrap', 'build', 'summary')
    $allPhasesOk = $true
    $phaseExitCodes = @{}

    foreach ($phase in $orderedPhases) {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript `
            -RunPhase $phase -ProjectPath $verifyProjectPath -NonInteractive 2>&1 | Out-String
        $exit = $LASTEXITCODE
        $phaseExitCodes[$phase] = $exit
        if ($exit -ne 0) {
            $allPhasesOk = $false
            Write-Host "  --- -RunPhase $phase failed (exit $exit) ---" -ForegroundColor Yellow
            Write-Host ($out -split "`n" | Select-Object -Last 10 | Out-String)
        }
    }

    # Get-StateFilePath is a function dot-sourced into this session by Group
    # 2 above (still defined in memory even though $funcOnlyPath itself was
    # deleted after Group 3) -- reuse it rather than duplicating its hashing
    # logic here and risking the two drifting apart.
    $stateFile = Get-StateFilePath $verifyProjectPath
    $perPhaseState = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { $null }

    # Now the same project via one continuous default (no -RunPhase) run --
    # exactly how this script has always been invoked before this refactor.
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript `
        -ProjectPath $verifyProjectPath -NonInteractive 2>&1 | Out-Null
    $fullRunExit = $LASTEXITCODE
    $fullRunState = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { $null }

    $statesMatch = $false
    if ($perPhaseState -and $fullRunState) {
        $statesMatch = ($perPhaseState.ProjectPath -eq $fullRunState.ProjectPath) -and
                       ($perPhaseState.RepoPath -eq $fullRunState.RepoPath) -and
                       ($perPhaseState.CoreDir -eq $fullRunState.CoreDir) -and
                       ($perPhaseState.Installed.git -eq $fullRunState.Installed.git) -and
                       ($perPhaseState.Installed.python -eq $fullRunState.Installed.python) -and
                       ($perPhaseState.Installed.cmake -eq $fullRunState.Installed.cmake) -and
                       ($perPhaseState.Installed.code -eq $fullRunState.Installed.code)
    }

    $passed = $allPhasesOk -and ($fullRunExit -eq 0) -and $statesMatch
    $failedPhases = ($phaseExitCodes.GetEnumerator() | Where-Object { $_.Value -ne 0 } | ForEach-Object { $_.Key }) -join ','
    Record-Result 'Per-phase sequence matches a full run' $passed `
        "all-11-phases-exit-0=$allPhasesOk (failed: $failedPhases), full-run-exit=$fullRunExit, states-match=$statesMatch"
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
