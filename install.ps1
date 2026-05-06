# claude-win-container — interactive installer.
#
# Run from any PowerShell prompt:
#
#   irm https://raw.githubusercontent.com/vinylflamingo/claude-win-container/main/install.ps1 | iex
#
# What it does:
#   1. Shows a security primer about why the sandbox restricts network access
#   2. Downloads cwc.ps1 + supporting files into %USERPROFILE%\.cwc\
#   3. Adds a `cwc` alias to your PowerShell $PROFILE (idempotent)
#   4. Walks you through firewall configuration: LAN subnets, host services,
#      custom FQDN -> IP mappings — writes the answers to ~/.cwc/config.json
#
# Pre-requisites: Docker Desktop in Windows-containers mode, PowerShell 5.1+.
# The container image itself is pulled on first `cwc` run.
#
# Skip the firewall wizard with -SkipFirewallSetup.
# For local development:
#   -LocalSource <path>   copy files from disk instead of downloading from GitHub
#   -Test                 run end-to-end in an isolated sandbox: USERPROFILE is
#                         redirected to a temp dir, $PROFILE is left alone,
#                         LocalSource defaults to the script's own dir, and
#                         everything is cleaned up on exit. Walk the wizard,
#                         see your config.json, no permanent changes.

[CmdletBinding()]
param(
    [string]$Ref                = 'main',
    [string]$InstallDir         = (Join-Path $env:USERPROFILE '.cwc'),
    [string]$LocalSource        = '',
    [switch]$NoProfileEdit,
    [switch]$SkipFirewallSetup,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$base = "https://raw.githubusercontent.com/vinylflamingo/claude-win-container/$Ref"

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

# Helpers
function Write-Section([string]$title) {
    Write-Host ""
    Write-Host ("═" * 64) -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ("═" * 64) -ForegroundColor Cyan
    Write-Host ""
}

function Read-YesNo([string]$prompt, [bool]$default = $false) {
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $resp = Read-Host "$prompt $hint"
        if (-not $resp) { return $default }
        switch -Regex ($resp.Trim().ToLower()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Host "  Please answer yes or no." -ForegroundColor Yellow }
        }
    }
}

function Read-NonEmpty([string]$prompt) {
    while ($true) {
        $resp = Read-Host $prompt
        if ($resp -and $resp.Trim()) { return $resp.Trim() }
        Write-Host "  Required." -ForegroundColor Yellow
    }
}

function Read-PressEnter([string]$prompt = 'Press Enter to continue (Ctrl+C to abort)') {
    Read-Host $prompt | Out-Null
}

# Detect non-interactive runs (CI, automation, scripted) so we don't hang on Read-Host.
# -SkipFirewallSetup forces non-interactive even on real consoles.
# We check three signals because no single one is reliable:
#   1. The user passed -SkipFirewallSetup
#   2. The host name suggests no UI ('Default Host' = no host attached)
#   3. PowerShell was launched with -NonInteractive (we read that from the process args)
$cmdLine = ([Environment]::GetCommandLineArgs() -join ' ')
$isNonInteractive = $cmdLine -match '(?i)\B-NonInteractive\b'
$interactive = (-not $SkipFirewallSetup) -and `
               ($Host.Name -ne 'Default Host') -and `
               (-not $isNonInteractive) -and `
               ([Environment]::UserInteractive)

try {

if ($Test) {
    Write-Section "TEST MODE — sandboxed install"
    Write-Host "  USERPROFILE redirected to: $testSandbox" -ForegroundColor Magenta
    Write-Host "  Source: $LocalSource" -ForegroundColor DarkGray
    Write-Host "  Real ~/.cwc and `$PROFILE will NOT be modified." -ForegroundColor DarkGray
    Write-Host "  Sandbox is removed on exit." -ForegroundColor DarkGray
}

# 1. Security primer
Write-Section "claude-win-container installer"
Write-Host "This tool runs Claude Code inside a sandboxed Windows container."
Write-Host ""
Write-Host "Why the sandbox restricts network access:" -ForegroundColor Yellow
Write-Host "  Claude (and any MCP server it spawns) can execute commands. By default"
Write-Host "  we BLOCK the sandbox from reaching:"
Write-Host "    - Other machines on your LAN (10/8, 172.16/12, 192.168/16, 169.254/16)"
Write-Host "    - IPv6 link-local / unique-local addresses"
Write-Host ""
Write-Host "  Public internet remains accessible — Claude needs api.anthropic.com,"
Write-Host "  npm, github, etc. to function."
Write-Host ""
Write-Host "  The next prompts let you allow specific exceptions for services you"
Write-Host "  actually use (a Traefik on your host, a network printer, an internal"
Write-Host "  API). Skip anything you're unsure about — you can always change it"
Write-Host "  later with ``cwc firewall ...``"
Write-Host ""
if ($interactive) { Read-PressEnter }

# 2. Download files
Write-Section "Installing launcher into $InstallDir"

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }

$files = @(
    @{ rel = 'cwc.ps1';                              dest = 'cwc.ps1' }
    @{ rel = 'docker-compose.yml';                   dest = 'docker-compose.yml' }
    @{ rel = 'overlays/project-overlay.example.yml'; dest = 'project-overlay.example.yml' }
)

if ($LocalSource) {
    $LocalSource = (Resolve-Path -LiteralPath $LocalSource).Path
    Write-Host "  (copying from local source: $LocalSource)" -ForegroundColor DarkGray
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
        Invoke-WebRequest -Uri "$base/$($f.rel)" -OutFile $dest -UseBasicParsing
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

# 4. Firewall wizard
$cwcConfigPath = Join-Path $env:USERPROFILE '.cwc\config.json'

if (-not $interactive) {
    Write-Host ""
    Write-Host "Skipping firewall wizard (non-interactive). Run ``cwc firewall list``" -ForegroundColor DarkGray
    Write-Host "later to configure, or re-run install.ps1 in an interactive session." -ForegroundColor DarkGray
    $SkipFirewallSetup = $true
} else {
    $existingConfig = $null
    if (Test-Path $cwcConfigPath) {
        $existingConfig = Get-Content -LiteralPath $cwcConfigPath -Raw | ConvertFrom-Json
        Write-Section "Existing firewall config detected"
        Write-Host "Found: $cwcConfigPath" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Lockdown   : $(if ($existingConfig.lockdown_lan) { 'enabled' } else { 'disabled' })"
        Write-Host "  Allow CIDRs: $(if ($existingConfig.allow_nets) { (@($existingConfig.allow_nets)) -join ', ' } else { '(none)' })"
        if ($existingConfig.extra_hosts) {
            $hostList = @($existingConfig.extra_hosts.PSObject.Properties | ForEach-Object { "$($_.Name) -> $($_.Value)" })
            Write-Host "  Host maps  : $(if ($hostList) { $hostList -join '; ' } else { '(none)' })"
        }
        Write-Host ""
        if (-not (Read-YesNo "Reconfigure (this will replace the existing config)?" $false)) {
            Write-Host "  Keeping existing config." -ForegroundColor DarkGray
            $SkipFirewallSetup = $true
        }
    }
}

if (-not $SkipFirewallSetup) {
    Write-Section "Configure network access"
    Write-Host "Answer these to set up your firewall. Press Enter at any [y/N]"
    Write-Host "to accept the default. Change anything later with ``cwc firewall ...``"
    Write-Host ""

    $config = [ordered]@{
        lockdown_lan = $true
        allow_nets   = @()
        extra_hosts  = @{}
        mounts       = @{}
    }

    # Q1 — public internet (informational)
    Write-Host "1. Public internet (Anthropic API, npm registry, GitHub):" -ForegroundColor Green
    Write-Host "   Always allowed. Required for Claude to function."
    Write-Host ""

    # Q2 — LAN subnets
    Write-Host "2. LAN services" -ForegroundColor Green
    Write-Host "   Examples: a network printer at 192.168.1.50, a NAS at 10.0.0.5,"
    Write-Host "   another machine on your dev network."
    if (Read-YesNo "   Do you need to reach any LAN subnets?") {
        Write-Host "   Enter CIDRs (e.g. 192.168.1.0/24, 10.5.0.0/16). Press Enter at"
        Write-Host "   the next prompt to stop adding."
        while ($true) {
            $cidr = Read-Host "     CIDR (or Enter to finish)"
            if (-not $cidr -or -not $cidr.Trim()) { break }
            $cidr = $cidr.Trim()
            if ($cidr -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
                Write-Host "     '$cidr' doesn't look like a CIDR. Try again." -ForegroundColor Yellow
                continue
            }
            $config.allow_nets += $cidr
            Write-Host "     ✓ added $cidr" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # Q3 — host services via host-gateway
    Write-Host "3. Services on your Docker host" -ForegroundColor Green
    Write-Host "   Examples: Traefik on 127.0.0.1:443, a local API server, another"
    Write-Host "   docker-compose stack bound to host ports. We map the FQDN to the"
    Write-Host "   Docker host's IP and auto-allow it through the lockdown."
    if (Read-YesNo "   Do you have any?") {
        Write-Host "   Enter the FQDN (DNS name) you'll use to reach the service. Press"
        Write-Host "   Enter at the next prompt to stop adding."
        while ($true) {
            $fqdn = Read-Host "     Service FQDN (or Enter to finish)"
            if (-not $fqdn -or -not $fqdn.Trim()) { break }
            $fqdn = $fqdn.Trim()
            $config.extra_hosts[$fqdn] = 'host-gateway'
            Write-Host "     ✓ $fqdn -> host-gateway" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # Q4 — explicit FQDN -> IP (advanced)
    Write-Host "4. Custom FQDN -> IP mappings" -ForegroundColor Green
    Write-Host "   Less common. Use this if you want to map a name to a specific IP"
    Write-Host "   that isn't your Docker host (e.g. legacy.box -> 10.5.1.20)."
    if (Read-YesNo "   Add any custom mappings?") {
        while ($true) {
            $fqdn = Read-Host "     FQDN (or Enter to finish)"
            if (-not $fqdn -or -not $fqdn.Trim()) { break }
            $fqdn = $fqdn.Trim()
            $ip = Read-NonEmpty "     IP for $fqdn"
            $config.extra_hosts[$fqdn] = $ip
            # Auto-add containing /24 to allow_nets if it's RFC1918 and not already covered
            if ($ip -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$' -and
                $ip -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)') {
                $cidr = "$($Matches[1]).0/24"
                if ($config.allow_nets -notcontains $cidr) {
                    Write-Host "     (auto-allowing $cidr so $ip is reachable)" -ForegroundColor DarkGray
                    $config.allow_nets += $cidr
                }
            }
            Write-Host "     ✓ $fqdn -> $ip" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # Q5 — extra folder mounts
    Write-Host "5. Extra folders" -ForegroundColor Green
    Write-Host "   Mount additional folders into the container so claude can read them."
    Write-Host "   Common: an Obsidian vault, design specs, runbooks. Each gets a name and"
    Write-Host "   shows up at C:\docs\<name> inside the container. Read-only by default."
    if (Read-YesNo "   Add any folder mounts?") {
        while ($true) {
            $name = Read-Host "     Name (e.g. obsidian, specs — Enter to finish)"
            if (-not $name -or -not $name.Trim()) { break }
            $name = $name.Trim()
            if ($name -match '[^a-zA-Z0-9._-]') {
                Write-Host "     Name must be alphanumeric (with . _ - allowed)." -ForegroundColor Yellow
                continue
            }
            $path = Read-NonEmpty "     Host path (e.g. C:\Users\you\Obsidian\Notes)"
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Host "     Path doesn't exist — adding anyway, you can create it later." -ForegroundColor Yellow
            } else {
                $path = (Resolve-Path -LiteralPath $path).Path
            }
            $writable = Read-YesNo "     Make it writable? (default: read-only)" $false
            $config.mounts[$name] = @{
                source   = $path
                target   = "C:\docs\$name"
                readonly = (-not $writable)
            }
            $modeLabel = if ($writable) { 'RW' } else { 'RO' }
            Write-Host "     ✓ $name [$modeLabel] $path -> C:\docs\$name" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # Summary + save
    Write-Section "Summary"
    Write-Host "  LAN lockdown : enabled"
    Write-Host "  Allow CIDRs  : $(if ($config.allow_nets.Count) { $config.allow_nets -join ', ' } else { '(none)' })"
    if ($config.extra_hosts.Count -gt 0) {
        Write-Host "  Host mappings:"
        foreach ($k in $config.extra_hosts.Keys) {
            Write-Host "    $k -> $($config.extra_hosts[$k])"
        }
    } else {
        Write-Host "  Host mappings: (none)"
    }
    if ($config.mounts.Count -gt 0) {
        Write-Host "  Folder mounts:"
        foreach ($k in $config.mounts.Keys) {
            $m = $config.mounts[$k]
            $mode = if ($m.readonly) { 'RO' } else { 'RW' }
            Write-Host "    $k [$mode]  $($m.source) -> $($m.target)"
        }
    } else {
        Write-Host "  Folder mounts: (none)"
    }
    Write-Host ""

    if (Read-YesNo "Save this config?" $true) {
        $cwcConfigDir = Split-Path -Parent $cwcConfigPath
        if (-not (Test-Path $cwcConfigDir)) { New-Item -ItemType Directory -Force -Path $cwcConfigDir | Out-Null }
        @{
            lockdown_lan = $config.lockdown_lan
            allow_nets   = @($config.allow_nets)
            extra_hosts  = $config.extra_hosts
            mounts       = $config.mounts
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cwcConfigPath
        Write-Host "  ✓ saved to $cwcConfigPath" -ForegroundColor Green
    } else {
        Write-Host "  Skipped. Default lockdown applies on next ``cwc`` run." -ForegroundColor DarkGray
    }
}

# 5. Done
Write-Section "Done"
if ($Test) {
    Write-Host "Test mode complete. Sandbox state below; all of it will be removed shortly."
} else {
    Write-Host "Open a new PowerShell session and run from a project directory:"
    Write-Host ""
    Write-Host "  cd C:\path\to\my-project"
    Write-Host "  cwc                       # first run pulls the image (~6 GB)"
    Write-Host ""
    Write-Host "Other commands:"
    Write-Host "  cwc help                  # full usage"
    Write-Host "  cwc firewall list         # show current firewall config"
    Write-Host "  cwc firewall host-add <fqdn>     # add a host mapping"
    Write-Host "  cwc firewall allow <cidr>        # add a LAN allow"
    Write-Host ""
    Write-Host "Pin a specific image version:"
    Write-Host "  `$env:CWC_IMAGE = 'vinylflamingo/claude-win-container:1.0.0'"
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

        $cfg = Join-Path $testSandbox '.cwc\config.json'
        if (Test-Path $cfg) {
            Write-Host "config.json:" -ForegroundColor DarkGray
            Get-Content $cfg
            Write-Host ""
        } else {
            Write-Host "config.json was NOT written (wizard skipped or you declined to save)." -ForegroundColor DarkGray
        }

        # Restore real env, remove sandbox
        $env:USERPROFILE = $realUserProfile
        if (Test-Path $testSandbox) { Remove-Item -Recurse -Force $testSandbox }

        Write-Host "Cleanup complete. USERPROFILE restored, sandbox removed." -ForegroundColor DarkGray
        $realCfg = Join-Path $realUserProfile '.cwc\config.json'
        Write-Host "Real ~/.cwc/config.json: $(if (Test-Path $realCfg) { 'still present (untouched)' } else { 'not present (untouched)' })" -ForegroundColor DarkGray
    }
}
