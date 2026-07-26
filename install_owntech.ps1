<#
OwnTech environment installer (Windows).

Automates Steps 1-6 of docs/environment_setup.md: project folder, VS Code,
PlatformIO extension, cloning Core, and a first build. See
windows_installer_plan.md for the full design (phases, rationale, testing).

Idempotent: safe to re-run on a machine that's already partially set up.
Each phase validates its own outcome and reports what failed, why, and how
to fix it, rather than trusting an installer's exit code blindly.

Usage (elevated PowerShell recommended, not strictly required):
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    .\install_owntech.ps1
    .\install_owntech.ps1 -ProjectPath C:\owntech
    .\install_owntech.ps1 -ProjectPath C:\owntech -SkipBuildTest
    .\install_owntech.ps1 -ProjectPath C:\owntech -BundleUrl <release-asset-url> -BundleSha256 <sha256>
#>

[CmdletBinding()]
param(
    [string]$ProjectPath,
    [switch]$SkipBuildTest,
    [switch]$NonInteractive,
    # Optional pre-baked PlatformIO packages/platforms bundle (see
    # build_platformio_bundle.ps1) to seed a fresh machine's PlatformIO core
    # dir from, so a first-ever install doesn't fetch the full toolchain and
    # framework set from scratch. Safe to omit -- the build just falls back
    # to a normal full download via 'pio run'. Only matters on the very first
    # run on a given machine; every run after that reuses its own local cache
    # regardless.
    [string]$BundleUrl,
    [string]$BundleSha256,
    # Run a single named phase in isolation instead of the full sequence --
    # for a future GUI wizard driving one progress bar per phase (see
    # windows_installer_plan.md, "Per-phase refactor implementation plan").
    # -ProjectPath is required with this (except for 'preflight', which is
    # what resolves it in the first place) since each invocation is a fresh
    # process with no memory of a prior phase's choices -- state is instead
    # read from/written to <ProjectPath>\.owntech_install_state.json.
    # Omitting -RunPhase runs every phase in order in one process, exactly
    # as this script has always worked.
    [string]$RunPhase,
    [switch]$ListPhases
)

$ErrorActionPreference = 'Continue'
# Intentionally not 'Stop': on PowerShell 5.1, native commands (git, pip, pio,
# winget, code) that write anything at all to stderr -- including routine
# progress text and deprecation notices -- get treated as terminating errors
# under 'Stop', killing the script on completely benign output. Every native
# call in this script is instead checked explicitly via $LASTEXITCODE.

$ProgressPreference = 'SilentlyContinue'
# On PowerShell 5.1, Invoke-WebRequest's default per-chunk progress-bar
# rendering makes large downloads dramatically slower -- measured at 378.2s
# vs. 4.9s (77x) for the same 0.36GB file over localhost, with no other
# variable changed. This script downloads a package bundle, get-platformio.py,
# and (as of the 7za.exe fetch below) a NuGet package, so this one setting
# affects every download the script makes.

$script:InstallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------

function Write-Phase($Title) {
    $elapsed = $script:InstallStopwatch.Elapsed.ToString('mm\:ss')
    Write-Host ""
    Write-Host "== [$elapsed] $Title ==" -ForegroundColor Cyan
}

function Write-Info($Message) { Write-Host "  $Message" }
function Write-Ok($Message) { Write-Host "  [ok] $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "  [warn] $Message" -ForegroundColor Yellow }

function Stop-Install($Reason, $Remediation) {
    $elapsed = $script:InstallStopwatch.Elapsed.ToString('hh\:mm\:ss')
    Write-Host ""
    Write-Host "  [FAILED] $Reason" -ForegroundColor Red
    if ($Remediation) {
        Write-Host "  How to fix: $Remediation" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Installer stopped after $elapsed. Re-run the script after fixing the issue above; already-completed steps will be skipped." -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------------------
# General helpers
# ----------------------------------------------------------------------------

function Test-Cmd($Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-WithRetry {
    # Absorbs transient network blips (a dropped connection, a momentary DNS
    # hiccup) without requiring the user to notice a failure and manually
    # re-run the whole script. $Action must throw on failure -- for native
    # commands (git, etc.) that signal failure via $LASTEXITCODE instead of an
    # exception, the caller's scriptblock must check it and throw itself. Not
    # used for extraction/build steps: those failing is more likely a real
    # problem (corrupt download, disk space) than a transient blip, and
    # retrying them blindly would just waste time or mask the real error.
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Description = 'operation',
        [int]$MaxAttempts = 3,
        [int]$InitialDelaySeconds = 2
    )
    $attempt = 1
    $delay = $InitialDelaySeconds
    while ($true) {
        try {
            & $Action
            return
        } catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }
            Write-Warn "$Description failed (attempt $attempt/$MaxAttempts): $($_.Exception.Message). Retrying in ${delay}s..."
            Start-Sleep -Seconds $delay
            $attempt++
            $delay *= 2
        }
    }
}

function Install-VSCodeExtension($Id, $DisplayName, [switch]$Required) {
    $hasExtension = (code --list-extensions 2>$null) -contains $Id
    if ($hasExtension) {
        Write-Ok "$DisplayName extension already installed."
        return
    }
    Write-Info "Installing $DisplayName extension..."
    code --install-extension $Id --force | Out-Null
    $hasExtension = (code --list-extensions 2>$null) -contains $Id
    if (-not $hasExtension) {
        if ($Required) {
            Stop-Install "$DisplayName extension did not appear in 'code --list-extensions' after install." `
                "Open VS Code, go to Extensions, and install '$DisplayName' manually, then re-run this script."
        }
        Write-Warn "$DisplayName extension did not appear in 'code --list-extensions' after install -- continuing without it (not required for the build)."
        return
    }
    Write-Ok "$DisplayName extension installed."
}

function Get-StateFilePath($ProjectPath) {
    return Join-Path $ProjectPath '.owntech_install_state.json'
}

function Get-InstallState($ProjectPath) {
    # Carries state across process boundaries for -RunPhase (see below) --
    # each isolated phase invocation is a fresh process with no memory of
    # what earlier phases computed, unlike today's single continuous run.
    # Returns an ordered hashtable (not the PSCustomObject ConvertFrom-Json
    # produces) so callers can keep using $state.Installed.Keys / bracket
    # assignment exactly like the existing in-memory $installed hashtable --
    # PowerShell 5.1's ConvertFrom-Json has no -AsHashtable, so this converts
    # manually, same pattern already used in Set-VSCodeAutoRebuildSetting.
    $path = Get-StateFilePath $ProjectPath
    $state = [ordered]@{
        ProjectPath = $ProjectPath
        RepoPath    = $null
        CoreDir     = $null
        Installed   = [ordered]@{}
    }
    if (Test-Path $path) {
        try {
            $parsed = Get-Content $path -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.RepoPath) { $state.RepoPath = $parsed.RepoPath }
            if ($parsed.CoreDir) { $state.CoreDir = $parsed.CoreDir }
            if ($parsed.Installed) {
                $parsed.Installed.PSObject.Properties | ForEach-Object { $state.Installed[$_.Name] = $_.Value }
            }
        } catch {
            Write-Warn "Could not parse install state file at $path ($($_.Exception.Message)) -- starting fresh."
        }
    }
    return $state
}

function Save-InstallState($ProjectPath, $State) {
    $path = Get-StateFilePath $ProjectPath
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding utf8
}

function Test-PythonReal {
    # On many Windows 10/11 machines, 'python' resolves to the Microsoft Store
    # "App execution alias" stub (%LOCALAPPDATA%\Microsoft\WindowsApps\python.exe)
    # even when no real Python is installed. Get-Command finds it happily, but
    # running it just prints a Store nag and exits -- it is not a working
    # interpreter. Verify by actually invoking it and checking the output.
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    if ($cmd.Source -like '*WindowsApps*') { return $false }
    try {
        $verOutput = & python --version 2>&1
    } catch {
        return $false
    }
    return ($verOutput -match '^Python \d')
}

function Update-SessionPath {
    # winget/installers write PATH to the registry; this process's $env:Path
    # won't see it until we re-read Machine + User PATH ourselves.
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Install-WingetApp($Id, $DisplayName, $VerifyCommand, $VerifyScriptBlock) {
    # Inlined rather than calling Test-Cmd: .GetNewClosure() captures variables
    # from the enclosing scope but not function definitions, so a closure that
    # calls another script-defined function can fail to resolve it depending
    # on where it's later invoked from. Get-Command is a builtin, always safe.
    $verify = if ($VerifyScriptBlock) { $VerifyScriptBlock } else { { [bool](Get-Command $VerifyCommand -ErrorAction SilentlyContinue) }.GetNewClosure() }

    if (& $verify) {
        Write-Ok "$DisplayName already installed, skipping."
        return
    }

    Write-Info "Installing $DisplayName ($Id) via winget..."
    $script:lastWingetExitCode = 0
    $wingetSucceeded = $true
    try {
        Invoke-WithRetry -Description "$DisplayName install (winget)" -Action {
            winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
            $script:lastWingetExitCode = $LASTEXITCODE
            if ($script:lastWingetExitCode -ne 0) {
                throw "winget exited with code $($script:lastWingetExitCode)"
            }
        }
    } catch {
        # Retries exhausted -- fall through to the checks below for a
        # specific, actionable error rather than the retry's own message.
        $wingetSucceeded = $false
    }

    Update-SessionPath

    if (& $verify) {
        Write-Ok "$DisplayName installed."
        return
    }

    if (-not $wingetSucceeded) {
        Stop-Install "$DisplayName install failed (winget exit code $script:lastWingetExitCode) after retries." `
            "Try running 'winget install --id $Id -e' manually to see the full error, or install $DisplayName from its official site."
    }

    Stop-Install "$DisplayName was installed by winget but is still not usable on PATH ('$VerifyCommand')." `
        "Close and reopen your terminal (PATH changes need a fresh session) and re-run this script. If this is Python, also check Settings > Apps > Advanced app settings > App execution aliases and turn OFF the 'python.exe'/'python3.exe' aliases, which can shadow a real install."
}

# ----------------------------------------------------------------------------
# Phase 0 - Preflight
# ----------------------------------------------------------------------------

function Test-WindowsVersion {
    $build = [System.Environment]::OSVersion.Version.Build
    # Windows 10 1809 = build 17763. Windows 11 builds are 22000+.
    if ($build -lt 17763) {
        Stop-Install "Windows build $build detected; Windows 10 1809 (build 17763) or later is required." `
            "Update Windows via Settings > Update & Security, then re-run this script."
    }
    Write-Ok "Windows build $build meets the minimum requirement (17763+)."
}

function Test-WingetAvailable {
    if (-not (Test-Cmd 'winget')) {
        Stop-Install "winget is not available on this machine." `
            "Install 'App Installer' from the Microsoft Store (https://apps.microsoft.com/detail/9nblggh4nns1), then re-run this script."
    }
    Write-Ok "winget is available."
}

function Get-FreeGB($DriveLetter) {
    $vol = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    if (-not $vol) { return $null }
    return [math]::Round($vol.Free / 1GB, 1)
}

function Test-DiskSpace($Path, $MinimumGB) {
    $driveLetter = $Path.Substring(0, 1)
    $freeGB = Get-FreeGB $driveLetter
    if ($null -eq $freeGB) {
        Write-Warn "Could not determine free space on drive $driveLetter`: -- skipping disk space check."
        return
    }
    if ($freeGB -lt $MinimumGB) {
        Stop-Install "Only $freeGB GB free on drive $driveLetter`:; at least $MinimumGB GB is recommended (PlatformIO downloads several hundred MB of toolchains on first build)." `
            "Free up disk space on drive $driveLetter`: and re-run this script."
    }
    Write-Ok "$freeGB GB free on drive $driveLetter`: (minimum $MinimumGB GB)."
}

function Set-PlatformIOCoreDir($ProjectPath) {
    # PlatformIO's default core dir (~/.platformio, on the system drive) is where
    # toolchain/framework downloads actually land -- hundreds of MB, dwarfing the
    # project checkout itself. On machines where the system drive is tight but the
    # project lives on a roomier drive, redirect the core dir there too, so the
    # build doesn't fail (or fill the system drive) despite Test-DiskSpace passing.
    $projectDrive = $ProjectPath.Substring(0, 1)
    $systemDrive = $env:SystemDrive.Substring(0, 1)
    $defaultCoreDir = Join-Path $env:USERPROFILE '.platformio'

    # Separately: some PlatformIO/Zephyr toolchain packages fail outright with
    # "Detected a whitespace character in framework path" if the core dir path
    # contains a space -- which %USERPROFILE%\.platformio does whenever the
    # Windows account name itself has one (e.g. "Unexpected Professor"). This
    # was masked in every earlier successful run on this project's dev machine
    # purely because its system drive happened to be low on space at the time,
    # incidentally triggering the redirect below for the disk-space reason
    # instead -- confirmed by this exact failure appearing the first time C:
    # had comfortable free space again. Redirect for this reason unconditionally
    # (regardless of drive or free space), since the target path below never
    # contains the username and so is always space-safe.
    $needsRedirectForSpaces = $defaultCoreDir -match '\s'

    if (-not $needsRedirectForSpaces) {
        if ($projectDrive -eq $systemDrive) {
            return
        }
        $systemFreeGB = Get-FreeGB $systemDrive
        if ($null -ne $systemFreeGB -and $systemFreeGB -ge 8) {
            return
        }
    }

    $coreDir = "$projectDrive`:\.platformio_core"
    if ($needsRedirectForSpaces) {
        Write-Warn "Windows account name contains a space ('$defaultCoreDir' would too) -- some PlatformIO/Zephyr toolchain packages can't handle that; redirecting PlatformIO's package cache to $coreDir instead."
    } else {
        $systemFreeGB = Get-FreeGB $systemDrive
        Write-Warn "$systemDrive`: has only $systemFreeGB GB free; redirecting PlatformIO's package cache to $coreDir instead of the default on $systemDrive`:."
    }
    [System.Environment]::SetEnvironmentVariable('PLATFORMIO_CORE_DIR', $coreDir, 'User')
    $env:PLATFORMIO_CORE_DIR = $coreDir
}

function Get-PlatformIOCoreDir {
    if ($env:PLATFORMIO_CORE_DIR) { return $env:PLATFORMIO_CORE_DIR }
    return Join-Path $env:USERPROFILE '.platformio'
}

function Get-SevenZipTool {
    # Standalone 7za.exe -- needed because Expand-Archive is dramatically slower
    # than 7-Zip at unpacking the bundle's ~45,000 small files: measured at
    # 832.9s vs. 115.7s-146.1s for the identical zip (see windows_installer_plan.md,
    # "Step 4 results"), and that gap turned out to be about the extraction tool
    # itself, not compression. A full winget-installed 7-Zip was rejected: it
    # installs fine unelevated on this project's target (non-admin) machines, but
    # 'winget uninstall' then fails with the same 1603 exit code CMake's uninstall
    # already hits here, so there's no clean way to remove it again afterward.
    # Instead this fetches the official "7-Zip.CommandLine" NuGet package -- a
    # .nupkg is just a zip file, so Expand-Archive can open it directly (no
    # bootstrapping problem), and the 7za.exe inside needs no installation at all,
    # so there's nothing to clean up afterward either.
    $toolsDir = Join-Path $env:TEMP 'owntech_7za'
    $candidates = @(
        (Join-Path $toolsDir 'tools\x64\7za.exe'),
        (Join-Path $toolsDir 'tools\7za.exe')
    )
    $existing = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($existing) {
        return $existing
    }

    Write-Info "Fetching standalone 7-Zip (7za.exe) to speed up package bundle extraction..."
    $nupkgUrl = 'https://www.nuget.org/api/v2/package/7-Zip.CommandLine/25.1.0'
    $nupkgPath = Join-Path $env:TEMP 'owntech_7zip_cmdline.zip'
    try {
        Invoke-WithRetry -Description "7za.exe download" -Action {
            Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgPath -UseBasicParsing -ErrorAction Stop
        }
        New-Item -ItemType Directory -Path $toolsDir -Force -ErrorAction SilentlyContinue | Out-Null
        Expand-Archive -Path $nupkgPath -DestinationPath $toolsDir -Force -ErrorAction Stop
    } catch {
        Write-Warn "Could not fetch the standalone 7-Zip tool ($($_.Exception.Message))."
        return $null
    } finally {
        Remove-Item $nupkgPath -Force -ErrorAction SilentlyContinue
    }

    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) {
        Write-Warn "Standalone 7-Zip tool did not land at the expected path after download -- NuGet package layout may have changed."
        return $null
    }
    Write-Ok "7za.exe ready at $found."
    return $found
}

function Invoke-BundleSeed($BundleUrl, $BundleSha256, $CoreDir) {
    if (-not $BundleUrl) {
        return
    }

    $packagesDir = Join-Path $CoreDir 'packages'
    $platformsDir = Join-Path $CoreDir 'platforms'
    if ((Test-Path $packagesDir) -or (Test-Path $platformsDir)) {
        Write-Ok "PlatformIO packages/platforms already present in $CoreDir, skipping bundle download."
        return
    }

    # 7-Zip is fetched before the (potentially large) bundle download so a
    # missing/unreachable tool is discovered -- and this whole optimization
    # skipped cleanly -- without wasting time downloading the bundle first.
    $sevenZip = Get-SevenZipTool
    if (-not $sevenZip) {
        Write-Warn "Skipping pre-baked package bundle (no extraction tool available) -- falling back to a full download during the build."
        return
    }

    Write-Info "Downloading pre-baked PlatformIO package bundle (avoids fetching the full toolchain/framework set from scratch)..."
    $zipPath = Join-Path $env:TEMP 'platformio_bundle.zip'
    try {
        Invoke-WithRetry -Description "package bundle download" -Action {
            Invoke-WebRequest -Uri $BundleUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        }
    } catch {
        Write-Warn "Could not download package bundle ($($_.Exception.Message)) -- falling back to a full download during the build."
        return
    }

    if ($BundleSha256) {
        $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash
        if ($actualHash -ne $BundleSha256) {
            Write-Warn "Package bundle checksum mismatch (expected $BundleSha256, got $actualHash) -- discarding and falling back to a full download."
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            return
        }
    }

    New-Item -ItemType Directory -Path $CoreDir -Force -ErrorAction SilentlyContinue | Out-Null
    try {
        & $sevenZip x $zipPath "-o$CoreDir" -y | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "7za.exe exited with code $LASTEXITCODE"
        }
        Write-Ok "Pre-baked package bundle extracted into $CoreDir. Any packages missing or out of date will still be fetched normally by the build below."
    } catch {
        Write-Warn "Could not extract package bundle ($($_.Exception.Message)) -- falling back to a full download during the build."
    } finally {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-ProjectPath($Path) {
    if ($Path -match '\s') {
        Stop-Install "Project path '$Path' contains spaces." `
            "Choose a path with no spaces, e.g. C:\owntech."
    }

    if ($Path.Length -ge 256) {
        Stop-Install "Project path '$Path' is $($Path.Length) characters; must be under 256." `
            "Choose a shorter path, e.g. C:\owntech."
    }

    $oneDriveEnv = @($env:OneDrive, $env:OneDriveCommercial) | Where-Object { $_ }
    $isUnderOneDrive = $false
    foreach ($od in $oneDriveEnv) {
        if ($Path -like "$od*") { $isUnderOneDrive = $true }
    }
    if ($Path -match 'OneDrive') { $isUnderOneDrive = $true }
    if ($isUnderOneDrive) {
        Stop-Install "Project path '$Path' is under a OneDrive-synced folder." `
            "Choose a path outside OneDrive, e.g. C:\owntech. OneDrive syncing can lock files mid-build and break PlatformIO."
    }

    $depth = ($Path.TrimEnd('\') -split '\\').Count
    if ($depth -gt 4) {
        Write-Warn "Project path '$Path' is nested $depth levels deep. Prefer a path close to the drive root (e.g. C:\owntech) to avoid Windows path-length issues later."
    }

    Write-Ok "Project path '$Path' passes validation (no spaces, not OneDrive, length OK)."
}

function Get-ProjectPath {
    if ($ProjectPath) {
        return $ProjectPath
    }
    if ($NonInteractive) {
        return 'C:\owntech'
    }
    $default = 'C:\owntech'
    $input = Read-Host "Project folder to create/use [$default]"
    if ([string]::IsNullOrWhiteSpace($input)) {
        return $default
    }
    return $input
}

# ----------------------------------------------------------------------------
# Phase 4 - Clone Core
# ----------------------------------------------------------------------------

function Get-RepoPath($ProjectPath) {
    if (Test-Path (Join-Path $ProjectPath '.git')) {
        # Already cloned here by a previous run of this script -- reuse it
        # directly rather than nesting a second clone inside it.
        return $ProjectPath
    }
    if (Test-Path $ProjectPath) {
        $existing = Get-ChildItem -Path $ProjectPath -Force -ErrorAction SilentlyContinue
        if ($existing -and ($existing.Count -gt 0)) {
            # Folder isn't empty and isn't our clone -- clone into a Core subfolder instead of colliding.
            return (Join-Path $ProjectPath 'Core')
        }
    }
    return $ProjectPath
}

function Test-CompleteClone($RepoPath) {
    # A .git folder existing isn't proof of a complete clone -- an interrupted
    # 'git clone' can leave one behind with a corrupt/incomplete object
    # database. 'git rev-parse HEAD' only succeeds if at least one real commit
    # is actually resolvable, a much stronger signal than the folder's mere
    # presence.
    if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
        return $false
    }
    Push-Location $RepoPath
    try {
        git rev-parse HEAD 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

function Invoke-CloneCore($RepoPath) {
    $repoUrl = 'https://github.com/owntech-foundation/Core'

    $hasGitFolder = Test-Path (Join-Path $RepoPath '.git')
    if ($hasGitFolder -and (Test-CompleteClone $RepoPath)) {
        Write-Ok "Core repository already cloned at $RepoPath, skipping clone."
    } else {
        if ($hasGitFolder) {
            # git can't resume a partial clone cleanly -- the correct recovery
            # from an interrupted previous run is to discard it and start
            # over, not to leave the user to diagnose a cryptic branch error.
            Write-Warn "Found an incomplete or corrupted clone at $RepoPath (likely from an interrupted previous run) -- removing it and re-cloning."
        }
        Write-Info "Cloning $repoUrl into $RepoPath ..."
        try {
            Invoke-WithRetry -Description "git clone" -Action {
                # Clear any partial state before each attempt -- 'git clone'
                # refuses to write into a non-empty directory, which a prior
                # failed attempt (in this loop or a previous run) can leave.
                Remove-Item $RepoPath -Recurse -Force -ErrorAction SilentlyContinue
                git clone $repoUrl $RepoPath
                if ($LASTEXITCODE -ne 0) {
                    throw "git clone exited with code $LASTEXITCODE"
                }
            }
        } catch {
            Stop-Install "git clone failed ($($_.Exception.Message))." `
                "Check your internet connection and that $RepoPath doesn't already contain conflicting files, then re-run this script."
        }
        Write-Ok "Cloned into $RepoPath."
    }

    Push-Location $RepoPath
    try {
        $branch = git rev-parse --abbrev-ref HEAD 2>$null
        if ($branch -ne 'main') {
            Stop-Install "Repository at $RepoPath is on branch '$branch', not 'main'." `
                "Run 'git -C `"$RepoPath`" checkout main' and re-run this script."
        }
        Write-Ok "On branch 'main'."
    } finally {
        Pop-Location
    }

    Set-VSCodeAutoRebuildSetting -RepoPath $RepoPath
}

function Set-VSCodeAutoRebuildSetting($RepoPath) {
    # PlatformIO IDE's autoRebuildAutocompleteIndex (default: on) rebuilds the
    # C/C++ IntelliSense index whenever it notices project changes -- slow on
    # a Zephyr project with this many include paths, and redundant right after
    # a fresh clone/build. This is a local, machine-specific override layered
    # on top of the upstream repo's own .vscode/settings.json (which we don't
    # control) rather than a change to the Core repo itself.
    $vscodeDir = Join-Path $RepoPath '.vscode'
    $settingsPath = Join-Path $vscodeDir 'settings.json'

    $settings = [ordered]@{}
    if (Test-Path $settingsPath) {
        try {
            $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $existing.PSObject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value }
        } catch {
            Write-Warn "Could not parse existing $settingsPath ($($_.Exception.Message)) -- leaving it untouched."
            return
        }
    } else {
        New-Item -ItemType Directory -Path $vscodeDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $settings['platformio-ide.autoRebuildAutocompleteIndex'] = $false
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding utf8
    Write-Ok "Disabled PlatformIO's automatic IntelliSense index rebuild in $settingsPath (run 'PlatformIO: Rebuild IntelliSense Index' manually if you need it)."
}

# ----------------------------------------------------------------------------
# Phase 5 - Smoke-test build
# ----------------------------------------------------------------------------

function Invoke-BuildSmokeTest($RepoPath) {
    $coreDir = Get-PlatformIOCoreDir
    $pioExe = Join-Path $coreDir 'penv\Scripts\platformio.exe'

    Invoke-BundleSeed -BundleUrl $BundleUrl -BundleSha256 $BundleSha256 -CoreDir $coreDir

    if (Test-Path $pioExe) {
        Write-Ok "PlatformIO Core already bootstrapped at $coreDir, skipping."
    } else {
        # Use the same get-platformio.py bootstrap the VS Code extension itself
        # uses -- it creates a self-contained venv at <core dir>\penv. A plain
        # 'pip install platformio' builds fine but does NOT create that layout,
        # so the extension doesn't recognize it as done and reinstalls its own
        # copy from scratch when the folder is opened. Bootstrapping it here
        # the same way means VS Code finds it already in place afterward.
        Write-Info "Bootstrapping PlatformIO Core into $coreDir (same layout the VS Code extension expects, so it won't redo this)..."
        $getPlatformioScript = Join-Path $env:TEMP 'get-platformio.py'
        try {
            Invoke-WithRetry -Description "get-platformio.py download" -Action {
                Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/platformio/platformio-core-installer/master/get-platformio.py' `
                    -OutFile $getPlatformioScript -UseBasicParsing -ErrorAction Stop
            }
        } catch {
            Stop-Install "Failed to download the PlatformIO Core bootstrap script." `
                "Check your internet connection, then re-run this script."
        }

        python $getPlatformioScript
        $bootstrapExit = $LASTEXITCODE

        if ($bootstrapExit -ne 0 -or -not (Test-Path $pioExe)) {
            Stop-Install "PlatformIO Core bootstrap failed (exit code $bootstrapExit)." `
                "Check your internet connection, then re-run this script (or re-run with -SkipBuildTest to skip this check)."
        }
        Write-Ok "PlatformIO Core bootstrapped at $coreDir."
    }

    Write-Info "Running first build in $RepoPath (this downloads toolchains/framework packages on first run, can take several minutes)..."
    Push-Location $RepoPath
    try {
        $buildOutput = & $pioExe run 2>&1
        $buildExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($buildExit -ne 0) {
        $tail = ($buildOutput | Select-Object -Last 25) -join "`n"
        Write-Host ""
        Write-Host "  Last 25 lines of build output:" -ForegroundColor Yellow
        Write-Host $tail
        Stop-Install "First build failed (exit code $buildExit)." `
            "See the build output above. Common causes: interrupted network mid-download, or antivirus blocking toolchain extraction. See docs/environment_setup.md#troubleshooting."
    }

    Write-Ok "Build succeeded."
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

$AllPhases = @('preflight', 'prereqs', 'vscode', 'extensions', 'clone', 'build', 'summary')

if ($ListPhases) {
    $AllPhases | ForEach-Object { Write-Output $_ }
    exit 0
}

function Invoke-PhasePreflight {
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host " OwnTech environment installer" -ForegroundColor Cyan
    Write-Host "===================================================" -ForegroundColor Cyan

    Write-Phase "Phase 0: Preflight"

    # Refresh PATH before detecting existing components: the process that
    # launched this script may hold a stale PATH from before an earlier run
    # (or an earlier manual install) updated the registry, which would
    # otherwise make an already-installed tool look missing in the summary.
    Update-SessionPath

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warn "Not running as Administrator. Machine-wide installs (Git, VS Code, CMake) may trigger individual UAC prompts. For a smoother run, re-launch PowerShell as Administrator."
    }

    Test-WindowsVersion
    Test-WingetAvailable

    $resolvedProjectPath = Get-ProjectPath
    Test-DiskSpace -Path $resolvedProjectPath -MinimumGB 5
    Test-ProjectPath -Path $resolvedProjectPath
    Set-PlatformIOCoreDir -ProjectPath $resolvedProjectPath

    if (-not (Test-Path $resolvedProjectPath)) {
        New-Item -ItemType Directory -Path $resolvedProjectPath -Force -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path $resolvedProjectPath)) {
            Stop-Install "Could not create project folder $resolvedProjectPath." `
                "Check that you have write permission to this location, then re-run this script."
        }
        Write-Ok "Created project folder $resolvedProjectPath."
    } else {
        Write-Ok "Project folder $resolvedProjectPath already exists."
    }

    $installed = [ordered]@{}
    $installed['git'] = Test-Cmd 'git'
    $installed['python'] = Test-PythonReal
    $installed['cmake'] = Test-Cmd 'cmake'
    $installed['code'] = Test-Cmd 'code'
    foreach ($k in $installed.Keys) {
        if ($installed[$k]) { Write-Ok "$k already detected on PATH." }
    }

    $state = Get-InstallState -ProjectPath $resolvedProjectPath
    $state.ProjectPath = $resolvedProjectPath
    $state.CoreDir = Get-PlatformIOCoreDir
    $state.Installed = $installed
    Save-InstallState -ProjectPath $resolvedProjectPath -State $state
    return $state
}

function Invoke-PhasePrereqs($State) {
    Write-Phase "Phase 1: Install prerequisites (Git, Python, CMake)"
    Install-WingetApp -Id 'Git.Git' -DisplayName 'Git' -VerifyCommand 'git'
    Install-WingetApp -Id 'Python.Python.3.12' -DisplayName 'Python 3.12' -VerifyCommand 'python' -VerifyScriptBlock { Test-PythonReal }
    Install-WingetApp -Id 'Kitware.CMake' -DisplayName 'CMake' -VerifyCommand 'cmake'
}

function Invoke-PhaseVSCode($State) {
    Write-Phase "Phase 2: Install Visual Studio Code"
    Install-WingetApp -Id 'Microsoft.VisualStudioCode' -DisplayName 'Visual Studio Code' -VerifyCommand 'code'
}

function Invoke-PhaseExtensions($State) {
    Write-Phase "Phase 3: Install PlatformIO IDE extension"
    Install-VSCodeExtension -Id 'platformio.platformio-ide' -DisplayName 'PlatformIO IDE' -Required
    # Not build-critical -- failing to install either of these shouldn't stop
    # the rest of setup, unlike PlatformIO IDE itself.
    Install-VSCodeExtension -Id 'shd101wyy.markdown-preview-enhanced' -DisplayName 'Markdown Preview Enhanced'
    Install-VSCodeExtension -Id 'mhutchie.git-graph' -DisplayName 'Git Graph'
}

function Invoke-PhaseClone($State) {
    Write-Phase "Phase 4: Clone the Core repository"
    $repoPath = Get-RepoPath -ProjectPath $State.ProjectPath
    Invoke-CloneCore -RepoPath $repoPath
    $State.RepoPath = $repoPath
    Save-InstallState -ProjectPath $State.ProjectPath -State $State
}

function Invoke-PhaseBuild($State) {
    if ($SkipBuildTest) {
        Write-Phase "Phase 5: Smoke-test build (skipped via -SkipBuildTest)"
        return
    }
    Write-Phase "Phase 5: Smoke-test build"
    Invoke-BuildSmokeTest -RepoPath $State.RepoPath
}

function Invoke-PhaseSummary($State) {
    Write-Phase "Phase 6: Summary"

    $script:InstallStopwatch.Stop()
    $totalElapsed = $script:InstallStopwatch.Elapsed.ToString('hh\:mm\:ss')

    Write-Host ""
    Write-Host "Setup complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Total install time: $totalElapsed"
    Write-Host "  Project folder: $($State.RepoPath)"
    Write-Host ""
    Write-Host "  Component status:"
    foreach ($k in $State.Installed.Keys) {
        $status = if ($State.Installed[$k]) { 'already present' } else { 'installed by this script' }
        Write-Host "    - $k`: $status"
    }
    Write-Host ""
    Write-Host "  Remaining manual steps:"
    Write-Host "    1. Connect your SPIN board via USB-C (its PWR LED should light up)."
    Write-Host "    2. In VS Code, use the Build (check mark) icon in the status bar."
    Write-Host "    3. Then Upload (arrow icon) to flash the board and see the LED blink."
    Write-Host ""

    if (-not $NonInteractive) {
        $openCode = Read-Host "Open the project in VS Code now? [Y/n]"
        if ($openCode -notmatch '^[Nn]') {
            code $State.RepoPath
        }
    }
}

if ($RunPhase) {
    if ($AllPhases -notcontains $RunPhase) {
        Write-Host "Unknown phase '$RunPhase'. Valid phases: $($AllPhases -join ', ')" -ForegroundColor Red
        exit 1
    }
    if ($RunPhase -ne 'preflight') {
        if (-not $ProjectPath) {
            Write-Host "-ProjectPath is required with -RunPhase $RunPhase (only 'preflight' can resolve/prompt for it)." -ForegroundColor Red
            exit 1
        }
        $state = Get-InstallState -ProjectPath $ProjectPath
    }
    switch ($RunPhase) {
        'preflight'  { Invoke-PhasePreflight | Out-Null }
        'prereqs'    { Invoke-PhasePrereqs $state }
        'vscode'     { Invoke-PhaseVSCode $state }
        'extensions' { Invoke-PhaseExtensions $state }
        'clone'      { Invoke-PhaseClone $state }
        'build'      { Invoke-PhaseBuild $state }
        'summary'    { Invoke-PhaseSummary $state }
    }
    exit 0
}

# Default: no -RunPhase, run every phase in order in this one process --
# behavior identical to how this script has always worked.
$state = Invoke-PhasePreflight
Invoke-PhasePrereqs $state
Invoke-PhaseVSCode $state
Invoke-PhaseExtensions $state
Invoke-PhaseClone $state
Invoke-PhaseBuild $state
Invoke-PhaseSummary $state
