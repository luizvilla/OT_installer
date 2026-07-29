<#
Packages a fully-populated PlatformIO core dir's `packages/` and `platforms/`
folders into a distributable zip -- the content that ordinarily gets fetched
fresh from the network the first time PlatformIO builds an OwnTech Core
project (toolchain, Zephyr framework, HAL modules).

Publish the resulting zip as a GitHub Release asset, then pass its download
URL (and the SHA256 this script prints) to install_owntech.ps1 via
-BundleUrl / -BundleSha256. A fresh machine then only downloads whatever
PlatformIO decides is missing or out of date on top of the bundle, instead of
the full set from scratch. Every run after a machine's first already reuses
its own local cache regardless -- this only speeds up first-ever installs.

Regenerate and re-publish whenever platformio.ini / west.yml bump a framework
or toolchain version. An install using a stale bundle still works correctly
(pio run fetches whatever's missing or mismatched) -- it just won't save any
download time for the parts that changed since the bundle was built.

Before (re-)publishing, see THIRD_PARTY_LICENSES.md -- a license inventory of
everything this script archives (toolchain, Zephyr framework, HAL modules,
build tools), verified against a real populated core dir (on Linux, but the
same PlatformIO package set applies here too). Two known gaps (tool-dtc,
tool-gperf: GPL binaries with no bundled license text) are documented there;
re-check it if platformio.ini/west.yml add a new dependency.

Usage:
    .\build_platformio_bundle.ps1 -CoreDir D:\.platformio_core
    .\build_platformio_bundle.ps1 -CoreDir D:\.platformio_core -OutFile bundle.zip

Get CoreDir from install_owntech.ps1's own output (it prints the redirected
core dir if your system drive was tight) or from
[System.Environment]::GetEnvironmentVariable('PLATFORMIO_CORE_DIR','User'),
falling back to $env:USERPROFILE\.platformio if that's unset.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CoreDir,
    [string]$OutFile = "platformio_bundle_$(Get-Date -Format 'yyyyMMdd').zip"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $CoreDir)) {
    Write-Error "CoreDir '$CoreDir' does not exist."
    exit 1
}

$packagesDir = Join-Path $CoreDir 'packages'
$platformsDir = Join-Path $CoreDir 'platforms'
$toZip = @('packages', 'platforms') | Where-Object { Test-Path (Join-Path $CoreDir $_) }

if ($toZip.Count -eq 0) {
    Write-Error "Neither 'packages' nor 'platforms' found under $CoreDir -- run a successful build first (install_owntech.ps1, or 'pio run' in a Core checkout) so PlatformIO populates them."
    exit 1
}

if (Test-Path $OutFile) {
    Remove-Item $OutFile -Force
}

Write-Host "Zipping $($toZip -join ', ') from $CoreDir into $OutFile ..." -ForegroundColor Cyan

# Compress-Archive needs to run from inside CoreDir so the zip's internal
# paths are 'packages/...' and 'platforms/...' -- matching what
# install_owntech.ps1's Expand-Archive expects when it extracts back into a
# fresh core dir on another machine.
Push-Location $CoreDir
try {
    Compress-Archive -Path $toZip -DestinationPath $OutFile -CompressionLevel Optimal
} finally {
    Pop-Location
}

$outPath = Resolve-Path $OutFile
$sizeGB = [math]::Round((Get-Item $outPath).Length / 1GB, 2)
$hash = (Get-FileHash -Path $outPath -Algorithm SHA256).Hash

Write-Host ""
Write-Host "Done: $outPath ($sizeGB GB)" -ForegroundColor Green
Write-Host "SHA256: $hash"
Write-Host ""

if ($sizeGB -gt 2) {
    Write-Host "WARNING: $sizeGB GB exceeds GitHub's per-file release asset limit (2GB)." -ForegroundColor Yellow
    Write-Host "Split 'packages' and 'platforms' into two separate archives/releases, and" -ForegroundColor Yellow
    Write-Host "update install_owntech.ps1's Invoke-BundleSeed to fetch and extract both." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "Next steps:"
Write-Host "  1. gh release create <tag> `"$outPath`" --title `"PlatformIO package bundle <tag>`""
Write-Host "     (or upload to an existing release: gh release upload <tag> `"$outPath`")"
Write-Host "  2. Run the installer with:"
Write-Host "     .\install_owntech.ps1 -BundleUrl <release-asset-download-url> -BundleSha256 $hash"
