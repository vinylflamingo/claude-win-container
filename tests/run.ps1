# tests/run.ps1 -- Layer 1 isolation tests.
#
# What it does:
#   1. Snapshots your real ~/.cwc/config.json so tests can mutate it freely
#   2. Creates fixture dirs (workspace, RO mount source, RW mount source)
#   3. Loads tests/lib/harness.ps1 then auto-discovers tests/*.tests.ps1
#   4. Each test sets a known config via Set-CwcConfig and asserts
#   5. On exit (success OR failure), restores your config and removes fixtures
#
# Usage:
#   .\tests\run.ps1                              # full suite, default image
#   .\tests\run.ps1 -Image claude-win-container:dev
#   .\tests\run.ps1 -Filter network              # only matching tests
#   .\tests\run.ps1 -NoCleanup                   # keep fixtures + config snapshot
#                                                #   for inspection after a failure
#
# Requires: docker desktop in Windows-containers mode, the cwc.ps1 alias resolvable,
# and the configured image (or its launcher will pull on first test).

[CmdletBinding()]
param(
    [string]$Image    = '',
    [string]$Filter   = '',
    [switch]$NoCleanup,
    [switch]$Build
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Resolve cwc -- the launcher next to this repo, not whatever's installed for the user.
$repoRoot = Split-Path -Parent $here
$cwcLauncher = Join-Path $repoRoot 'cwc.ps1'
if (-not (Test-Path $cwcLauncher)) {
    Write-Host "ERROR: cwc.ps1 not found next to tests/ ($cwcLauncher)" -ForegroundColor Red
    exit 1
}
Set-Alias cwc $cwcLauncher -Scope Script

# Image override
$savedImage = $env:CWC_IMAGE
if ($Image) { $env:CWC_IMAGE = $Image }

# Optional: rebuild the image before running. Strongly recommended when iterating
# on entrypoint.ps1 or Dockerfile changes -- the default image is the published one
# from Docker Hub, which won't have your local changes. Without -Build, container-
# tier tests (network, settings, harden) test the *published* image's behaviour,
# not your working tree.
if ($Build) {
    Write-Host "Building image from local Dockerfile..." -ForegroundColor Cyan
    $cwcLocal = if ($env:CWC_IMAGE) { $env:CWC_IMAGE } else { 'fcostoya/claude-win-container:dev' }
    $env:CWC_IMAGE = $cwcLocal
    & docker compose -f (Join-Path $repoRoot 'docker-compose.yml') build claude-code
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed; aborting." -ForegroundColor Red
        exit 1
    }
    Write-Host "Built $cwcLocal" -ForegroundColor Green
}

# Snapshot real user config
$realCfg  = Join-Path $env:USERPROFILE '.cwc\config.json'
$savedCfg = $null
if (Test-Path $realCfg) {
    $savedCfg = "$realCfg.test-backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item $realCfg $savedCfg -Force
    Write-Host "Snapshotted real config to $savedCfg" -ForegroundColor DarkGray
}

# Fixtures: a workspace dir + RO and RW mount sources
$fixturesRoot = Join-Path $env:TEMP "cwc-tests-$(Get-Random)"
$wsDir = New-Item -ItemType Directory -Force -Path "$fixturesRoot\workspace"
$roDir = New-Item -ItemType Directory -Force -Path "$fixturesRoot\mount-ro"
$rwDir = New-Item -ItemType Directory -Force -Path "$fixturesRoot\mount-rw"
'workspace marker' | Set-Content "$($wsDir.FullName)\WORKSPACE.txt"
'ro fixture content' | Set-Content "$($roDir.FullName)\readme.txt"
git init $wsDir.FullName *> $null
Write-Host "Fixtures at $fixturesRoot" -ForegroundColor DarkGray

# Test state (consumed by harness)
$script:fixtures = @{
    workspace = $wsDir.FullName
    ro        = $roDir.FullName
    rw        = $rwDir.FullName
}
$script:Filter   = $Filter
$script:results  = @()
$script:passed   = 0
$script:failed   = 0
$script:skipped  = 0

. (Join-Path $here 'lib\harness.ps1')

$startedAt = Get-Date

try {
    $testFiles = Get-ChildItem -Path $here -Filter '*.tests.ps1' | Sort-Object Name
    if (-not $testFiles) {
        Write-Host "No *.tests.ps1 files found in $here" -ForegroundColor Yellow
        exit 1
    }
    foreach ($tf in $testFiles) {
        Write-Host ""
        Write-Host "$($tf.BaseName)" -ForegroundColor Cyan
        . $tf.FullName
    }
} finally {
    $elapsed = (Get-Date) - $startedAt
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host ("  passed  : {0}" -f $script:passed) -ForegroundColor Green
    Write-Host ("  failed  : {0}" -f $script:failed) -ForegroundColor $(if ($script:failed) { 'Red' } else { 'DarkGray' })
    if ($script:skipped -gt 0) {
        Write-Host ("  skipped : {0}" -f $script:skipped) -ForegroundColor DarkGray
    }
    Write-Host ("  elapsed : {0:N1}s" -f $elapsed.TotalSeconds) -ForegroundColor DarkGray
    if ($script:failed -gt 0) {
        Write-Host ""
        Write-Host "Failures:" -ForegroundColor Red
        $script:results | Where-Object Status -eq 'fail' | ForEach-Object {
            Write-Host "  - [$($_.Category)] $($_.Name)" -ForegroundColor Red
            Write-Host "    $($_.Message -replace "(`r?`n)+", '; ')" -ForegroundColor DarkRed
        }
    }

    if (-not $NoCleanup) {
        # Restore config
        Remove-Item $realCfg -ErrorAction SilentlyContinue
        if ($savedCfg) {
            Move-Item $savedCfg $realCfg -Force
            Write-Host "Restored real ~/.cwc/config.json from snapshot" -ForegroundColor DarkGray
        }
        # Restore image env
        if ($null -ne $savedImage) { $env:CWC_IMAGE = $savedImage } else { Remove-Item Env:CWC_IMAGE -ErrorAction SilentlyContinue }
        # Remove fixtures
        if (Test-Path $fixturesRoot) { Remove-Item -Recurse -Force $fixturesRoot }
    } else {
        Write-Host ""
        Write-Host "(-NoCleanup) Fixtures kept at $fixturesRoot" -ForegroundColor Yellow
        if ($savedCfg) { Write-Host "(-NoCleanup) Config snapshot at $savedCfg" -ForegroundColor Yellow }
    }
}

if ($script:failed -gt 0) { exit 1 } else { exit 0 }
