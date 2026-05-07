# claude-win-container -- one-shot installer.
#
# Run from any PowerShell prompt:
#
#   irm https://github.com/vinylflamingo/claude-win-container/releases/latest/download/install.ps1 | iex
#
# What it does:
#   1. Shows a security primer about why the sandbox restricts network access
#   2. Downloads cwc.ps1 + supporting files into %USERPROFILE%\.cwc\
#   3. Adds a `cwc` alias to your PowerShell $PROFILE (idempotent)
#
# Per-project sandbox config (firewall rules, host services, mounts, harden) is
# configured the first time you run `cwc` in a project -- it auto-triggers an
# interactive setup wizard. You can also run `cwc setup` explicitly to reconfigure.
#
# Pre-requisites: Docker Desktop in Windows-containers mode, PowerShell 5.1+.
# The container image itself is pulled on first `cwc` run.
#
# For local development:
#   -LocalSource <path>   copy files from disk instead of downloading from GitHub
#   -Test                 run end-to-end in an isolated sandbox: USERPROFILE is
#                         redirected to a temp dir, $PROFILE is left alone,
#                         LocalSource defaults to the script's own dir, and
#                         everything is cleaned up on exit.
#
# -Ref accepts:
#   latest                  most-recent stable GitHub release (default; skips preview/*)
#   preview                 most-recent preview build (single moving GitHub release
#                           with literal tag `preview`; updated on every preview push)
#   v1.2.3                  exact stable release tag
#   main / release/x.y.z    branch ref (raw.githubusercontent.com fallback for dev)

[CmdletBinding()]
param(
    [string]$Ref         = 'latest',
    [string]$InstallDir  = (Join-Path $env:USERPROFILE '.cwc'),
    [string]$LocalSource = '',
    [switch]$NoProfileEdit,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'

# Resolve a download URL for one file. Four modes, chosen by the shape of $Ref:
#   - 'latest'       -> GitHub release "latest" redirect (skips prereleases). Asset
#                       names are flat (no directories), so we use $AssetName.
#   - 'preview'      -> the single moving GitHub release with literal tag `preview`,
#                       always pointing at the most recent preview build. Same flat
#                       asset namespace.
#   - tag like v*    -> specific GitHub release (stable). Same flat asset namespace.
#   - branch ref     -> raw.githubusercontent.com fallback. Preserves the in-repo
#                       path via $RelPath -- useful for testing an unreleased branch.
function Get-CwcDownloadUrl {
    param(
        [string]$Ref,
        [string]$RelPath,
        [string]$AssetName
    )
    if ($Ref -eq 'latest') {
        return "https://github.com/vinylflamingo/claude-win-container/releases/latest/download/$AssetName"
    } elseif ($Ref -eq 'preview') {
        return "https://github.com/vinylflamingo/claude-win-container/releases/download/preview/$AssetName"
    } elseif ($Ref -match '^v\d+\.\d+\.\d+') {
        return "https://github.com/vinylflamingo/claude-win-container/releases/download/$Ref/$AssetName"
    } else {
        return "https://raw.githubusercontent.com/vinylflamingo/claude-win-container/$Ref/$RelPath"
    }
}

# Test-mode setup: redirect USERPROFILE to a fresh sandbox dir and override defaults
# so nothing in the user's real home is touched. Cleaned up in the finally block.
$realUserProfile = $null
$testSandbox     = $null
if ($Test) {
    $realUserProfile = $env:USERPROFILE
    $testSandbox     = Join-Path $env:TEMP "cwc-test-$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $testSandbox | Out-Null
    $env:USERPROFILE = $testSandbox
    # Defaults computed from the real USERPROFILE; rebind to the sandbox.
    $InstallDir   = Join-Path $testSandbox '.cwc'
    $NoProfileEdit = $true
    if (-not $LocalSource -and $PSScriptRoot) {
        $LocalSource = $PSScriptRoot
    }
}

function Write-Section([string]$title) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host ""
}

function Read-PressEnter([string]$prompt = 'Press Enter to continue (Ctrl+C to abort)') {
    Read-Host $prompt | Out-Null
}

# Detect non-interactive runs (CI, automation, scripted) so we don't hang on Read-Host
# in the security-primer "press enter" prompt. We check three signals because no
# single one is reliable:
#   1. The host name suggests no UI ('Default Host' = no host attached)
#   2. PowerShell was launched with -NonInteractive (read from process args)
#   3. Environment.UserInteractive
$cmdLine = ([Environment]::GetCommandLineArgs() -join ' ')
$isNonInteractive = $cmdLine -match '(?i)\B-NonInteractive\b'
$interactive = ($Host.Name -ne 'Default Host') -and `
               (-not $isNonInteractive) -and `
               ([Environment]::UserInteractive)

try {

if ($Test) {
    Write-Section "TEST MODE -- sandboxed install"
    Write-Host "  USERPROFILE redirected to: $testSandbox" -ForegroundColor Magenta
    Write-Host "  Source: $LocalSource" -ForegroundColor DarkGray
    Write-Host "  Real ~/.cwc and `$PROFILE will NOT be modified." -ForegroundColor DarkGray
    Write-Host "  Sandbox is removed on exit." -ForegroundColor DarkGray
}

# 1. Security primer
Write-Section "claude-win-container installer"
Write-Host "This tool runs Claude Code inside a sandboxed Windows container."
Write-Host ""
Write-Host "What an AI coding agent can do:" -ForegroundColor Yellow
Write-Host "  Claude (and any MCP server it loads) can run commands, read and write"
Write-Host "  files, install packages, and make network requests on your behalf."
Write-Host "  That's the point -- but it also means an agent acting on a wrong"
Write-Host "  instruction (or a prompt injection from text it reads) can do harm."
Write-Host ""
Write-Host "What we sandbox by default:" -ForegroundColor Yellow
Write-Host "  - Filesystem    : agent sees only your project (mounted at C:\workspace)"
Write-Host "                    plus a per-project state dir. Your home folder isn't"
Write-Host "                    visible inside the container."
Write-Host "  - Network       : public internet is allowed (Anthropic, npm, github);"
Write-Host "                    LAN egress (10/8, 172.16/12, 192.168/16, 169.254/16,"
Write-Host "                    IPv6 ULA / link-local) is blackholed."
Write-Host "  - Auth scope    : OAuth tokens are shared across projects, but plugins"
Write-Host "                    and project-scoped settings stay per-project -- an"
Write-Host "                    agent in one project can't plant code that runs in"
Write-Host "                    another."
Write-Host "  - Workspace     : changes to .env, .mcp.json, or claude-sandbox.overlay.yml"
Write-Host "    trust           are detected and require explicit ack ('cwc trust') --"
Write-Host "                    the agent can't silently expand the next session's"
Write-Host "                    sandbox by editing files in the workspace."
Write-Host ""
Write-Host "What we DON'T sandbox:" -ForegroundColor Yellow
Write-Host "  - Public internet access. The agent can reach any public IP -- npm"
Write-Host "    packages, GitHub repos, arbitrary HTTPS endpoints. Code from npm"
Write-Host "    runs inside the container. This is by design."
Write-Host "  - Tool authority. Anything you allow the agent to run, it can run."
Write-Host "    Permissions are configured per-project via Claude's settings."
Write-Host ""
Write-Host "Per-project configuration:" -ForegroundColor Yellow
Write-Host "  Each project gets its own sandbox config (firewall rules, host services,"
Write-Host "  mounts, harden). The first time you run 'cwc' in a project, an interactive"
Write-Host "  setup wizard configures it -- you can also run 'cwc setup' explicitly to"
Write-Host "  reconfigure. cwc starts at the most restrictive defaults."
Write-Host ""
Write-Host "Full security model + threat analysis: docs/security.md"
Write-Host ""
if ($interactive) { Read-PressEnter }

# 2. Download files
Write-Section "Installing launcher into $InstallDir"

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }

# Per-file: rel = path inside the repo (used by branch-ref fallback and -LocalSource);
#           asset = flat filename as uploaded to the GitHub release.
$files = @(
    @{ rel = 'cwc.ps1';                              asset = 'cwc.ps1';                     dest = 'cwc.ps1' }
    @{ rel = 'docker-compose.yml';                   asset = 'docker-compose.yml';          dest = 'docker-compose.yml' }
    @{ rel = 'overlays/project-overlay.example.yml'; asset = 'project-overlay.example.yml'; dest = 'project-overlay.example.yml' }
)

if ($LocalSource) {
    $LocalSource = (Resolve-Path -LiteralPath $LocalSource).Path
    Write-Host "  (copying from local source: $LocalSource)" -ForegroundColor DarkGray
} else {
    Write-Host "  (downloading from $Ref)" -ForegroundColor DarkGray
}
foreach ($f in $files) {
    $dest = Join-Path $InstallDir $f.dest
    Write-Host "  - $($f.dest)" -ForegroundColor DarkGray
    if ($LocalSource) {
        $src = Join-Path $LocalSource ($f.rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Local source missing: $src"
        }
        Copy-Item -LiteralPath $src -Destination $dest -Force
    } else {
        $url = Get-CwcDownloadUrl -Ref $Ref -RelPath $f.rel -AssetName $f.asset
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    }
}

$launcher = Join-Path $InstallDir 'cwc.ps1'

# 3. PowerShell profile alias
if (-not $NoProfileEdit) {
    if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Force -Path $PROFILE | Out-Null }
    $aliasMarker = '# claude-win-container alias (managed by install.ps1)'
    $aliasLine   = "Set-Alias cwc '$launcher'"
    $existing    = Get-Content -LiteralPath $PROFILE -ErrorAction SilentlyContinue
    if ($existing -match [regex]::Escape($aliasMarker)) {
        $newContent = $existing -replace "(?m)^Set-Alias cwc .+$", $aliasLine
        Set-Content -LiteralPath $PROFILE -Value $newContent
        Write-Host "  - updated cwc alias in `$PROFILE" -ForegroundColor DarkGray
    } else {
        Add-Content -LiteralPath $PROFILE -Value ""
        Add-Content -LiteralPath $PROFILE -Value $aliasMarker
        Add-Content -LiteralPath $PROFILE -Value $aliasLine
        Write-Host "  - added cwc alias to `$PROFILE" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  - skipping `$PROFILE edit (-NoProfileEdit)" -ForegroundColor DarkGray
}

# 4. Done
Write-Section "Done"
if ($Test) {
    Write-Host "Test mode complete. Sandbox state below; all of it will be removed shortly."
} else {
    Write-Host "Open a new PowerShell session, then cd into any project and run cwc:"
    Write-Host ""
    Write-Host "  cd C:\path\to\my-project"
    Write-Host "  cwc                       # first run pulls the image (~6 GB)"
    Write-Host "                            # and triggers the per-project setup wizard"
    Write-Host ""
    Write-Host "Useful commands:"
    Write-Host "  cwc setup                 # (re-)run the per-project setup wizard"
    Write-Host "  cwc help                  # full usage"
    Write-Host "  cwc firewall list         # show this project's firewall config"
    Write-Host ""
    Write-Host "Pin a specific image version:"
    Write-Host "  `$env:CWC_IMAGE = 'fcostoya/claude-win-container:0.1.1'"
    Write-Host ""
}

} finally {
    if ($Test -and $realUserProfile) {
        Write-Section "Test sandbox state"

        Write-Host "Files written to $testSandbox :" -ForegroundColor DarkGray
        if (Test-Path $testSandbox) {
            Get-ChildItem -Recurse $testSandbox -Force |
                Select-Object @{n='Path';e={ $_.FullName.Replace($testSandbox,'<sandbox>') }},
                              @{n='Size';e={ if ($_.PSIsContainer) { '<dir>' } else { $_.Length } }} |
                Format-Table -AutoSize
        }

        # Restore real env, remove sandbox
        $env:USERPROFILE = $realUserProfile
        if (Test-Path $testSandbox) { Remove-Item -Recurse -Force $testSandbox }

        Write-Host "Cleanup complete. USERPROFILE restored, sandbox removed." -ForegroundColor DarkGray
    }
}
