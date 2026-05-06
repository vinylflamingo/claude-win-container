# claude-win-container -- interactive installer.
#
# Run from any PowerShell prompt:
#
#   irm https://github.com/vinylflamingo/claude-win-container/releases/latest/download/install.ps1 | iex
#
# What it does:
#   1. Shows a security primer about why the sandbox restricts network access
#   2. Downloads cwc.ps1 + supporting files into %USERPROFILE%\.cwc\
#   3. Adds a `cwc` alias to your PowerShell $PROFILE (idempotent)
#   4. Walks you through firewall configuration: LAN subnets, host services,
#      custom FQDN -> IP mappings -- writes the answers to ~/.cwc/config.json
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
#
# -Ref accepts:
#   latest                  most-recent stable GitHub release (default; skips preview/*)
#   v1.2.3                  exact release tag
#   main / release/x.y.z    branch ref (raw.githubusercontent.com fallback for dev)

[CmdletBinding()]
param(
    [string]$Ref                = 'latest',
    [string]$InstallDir         = (Join-Path $env:USERPROFILE '.cwc'),
    [string]$LocalSource        = '',
    [switch]$NoProfileEdit,
    [switch]$SkipFirewallSetup,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'

# Resolve a download URL for one file. Three modes, chosen by the shape of $Ref:
#   - 'latest'       -> GitHub release "latest" redirect (skips prereleases). Asset
#                       names are flat (no directories), so we use $AssetName.
#   - tag like v*    -> specific GitHub release. Same flat asset namespace.
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

# Helpers
function Write-Section([string]$title) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor Cyan
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
Write-Host "It is YOUR decision what the agent should and should not be able to"
Write-Host "access. cwc starts at the most restrictive defaults; you relax them"
Write-Host "with ``cwc firewall ...``, ``cwc mount ...``, and ``cwc harden ...``"
Write-Host "as your needs require."
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
        lockdown_lan   = $true
        allow_nets     = @()
        extra_hosts    = @{}
        mounts         = @{}
        harden_enabled = $false
    }

    # Q1 -- public internet (informational)
    Write-Host "1. Public internet (Anthropic API, npm registry, GitHub):" -ForegroundColor Green
    Write-Host "   Always allowed. Required for Claude to function."
    Write-Host ""

    # Q2 -- LAN subnets
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
            Write-Host "     OK added $cidr" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # Q3 -- host services via host-gateway
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
            Write-Host "     OK $fqdn -> host-gateway" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # Q4 -- explicit FQDN -> IP (advanced)
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
            Write-Host "     OK $fqdn -> $ip" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # Q5 -- extra folder mounts
    Write-Host "5. Extra folders" -ForegroundColor Green
    Write-Host "   Mount additional folders into the container so claude can read them."
    Write-Host "   Common: an Obsidian vault, design specs, runbooks. Each gets a name and"
    Write-Host "   shows up at C:\docs\<name> inside the container. Read-only by default."
    if (Read-YesNo "   Add any folder mounts?") {
        while ($true) {
            $name = Read-Host "     Name (e.g. obsidian, specs -- Enter to finish)"
            if (-not $name -or -not $name.Trim()) { break }
            $name = $name.Trim()
            if ($name -match '[^a-zA-Z0-9._-]') {
                Write-Host "     Name must be alphanumeric (with . _ - allowed)." -ForegroundColor Yellow
                continue
            }
            $path = Read-NonEmpty "     Host path (e.g. C:\Users\you\Obsidian\Notes)"
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Host "     Path doesn't exist -- adding anyway, you can create it later." -ForegroundColor Yellow
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
            Write-Host "     OK $name [$modeLabel] $path -> C:\docs\$name" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # Q6 -- harden offer
    Write-Host "6. Tamper-resistant hardening" -ForegroundColor Green
    Write-Host "   The default LAN lockdown is enforced inside the container -- code with"
    Write-Host "   admin rights in the container (which Claude has) can disable it via"
    Write-Host "   ``Remove-NetRoute``. 'Harden' adds an in-container watchdog that"
    Write-Host "   re-applies the routes every 2s, restores the hosts file from snapshot"
    Write-Host "   if changed, removes unauthorised routes, and logs new trust-store CAs."
    Write-Host ""
    Write-Host "   Trade-off: it's a bigger speed-bump, not real isolation. A determined"
    Write-Host "   agent can still defeat it (kill the watchdog, race the loop). Real"
    Write-Host "   isolation requires host-side enforcement which we haven't built yet"
    Write-Host "   (see docs/security.md -- host-side VFP enforcement is documented as"
    Write-Host "   future work). Harden raises the realistic bar without that."
    Write-Host ""
    Write-Host "   Recommended: ON. You can toggle later with 'cwc harden enable/disable'."
    if (Read-YesNo "   Enable hardening?" $true) {
        $config.harden_enabled = $true
        Write-Host "     OK harden enabled" -ForegroundColor DarkGray
    } else {
        $config.harden_enabled = $false
        Write-Host "     x harden disabled" -ForegroundColor DarkGray
    }
    Write-Host ""

    # Summary + save
    Write-Section "Summary"
    Write-Host "  LAN lockdown : enabled"
    Write-Host "  Harden       : $(if ($config.harden_enabled) { 'ENABLED' } else { 'disabled' })"
    Write-Host "  Allow CIDRs  : $(if ($config.allow_nets.Count) { $config.allow_nets -join ', ' } else { '(none)' })"
    if ($config.extra_hosts.Count -gt 0) {
        Write-Host "  Host mappings:"
        foreach ($k in $config.extra_hosts.Keys) {
            $entry = $config.extra_hosts[$k]
            $target = if ($entry -is [string]) { $entry } else { $entry.target }
            $ports  = if ($entry -is [hashtable] -and $entry.ports) { ($entry.ports -join ',') } else { '443,80 (default)' }
            Write-Host "    $k -> $target  ports=$ports"
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
        # Migrate any string-valued extra_hosts entries to {target, ports} schema. The wizard
        # itself doesn't add string values today, but defensive -- older code paths may have.
        $hostsOut = @{}
        foreach ($k in $config.extra_hosts.Keys) {
            $val = $config.extra_hosts[$k]
            if ($val -is [string]) {
                $hostsOut[$k] = @{ target = $val; ports = @(443, 80) }
            } else {
                $hostsOut[$k] = $val
            }
        }
        @{
            lockdown_lan   = $config.lockdown_lan
            allow_nets     = @($config.allow_nets)
            extra_hosts    = $hostsOut
            mounts         = $config.mounts
            harden_enabled = $config.harden_enabled
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cwcConfigPath
        Write-Host "  OK saved to $cwcConfigPath" -ForegroundColor Green
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
    Write-Host "  `$env:CWC_IMAGE = 'fcostoya/claude-win-container:0.1.0-alpha'"
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
