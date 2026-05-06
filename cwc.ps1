# cwc.ps1 — claude-win-container launcher.
# Launches a sandboxed Claude Code session against the current directory.
#
# Usage (from any project directory):
#   cwc                       # runs `claude` inside the container (pulls image if missing)
#   cwc powershell            # drops to a PowerShell prompt
#   cwc mcp list              # shorthand for `cwc claude mcp list` (any `mcp` subcommand)
#   cwc firewall {list|allow <cidr>|deny <cidr>|enable|disable|host-list|host-add <fqdn> [target]|host-remove <fqdn>}
#                             # manage LAN-egress lockdown + host mappings (persistent user-wide config)
#   cwc mount {list|add <name> <host-path> [ro|rw]|remove <name>}
#                             # mount extra folders into the container at C:\docs\<name>
#   cwc -Help / -h / help     # print this usage and exit
#   cwc -Pull                 # docker pull latest image then launch
#   cwc -Build                # build image from local Dockerfile (requires repo clone)
#   cwc -Force                # skip project-root heuristic (for non-standard dirs)
#   cwc -- <args>             # pass remaining args to claude (e.g. cwc -- --resume)
#
# Image selection:
#   $env:CWC_IMAGE = 'vinylflamingo/claude-win-container:1.2.3'   # pin a version
#   default = 'vinylflamingo/claude-win-container:latest'
#
# State layout:
#   %USERPROFILE%\.claude-win-container\
#     auth\                           # global OAuth tokens / API key cache (shared)
#     projects\<slug>\config\         # per-project Claude config (memory, sessions)
#     projects\<slug>\history\        # per-project shell history
#
# Slug = "<basename>-<sha1[0..11]>" of the absolute project path.

[CmdletBinding()]
param(
    [switch]$Build,
    [switch]$Pull,
    [switch]$Force,
    [Alias('h')]
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Cmd
)

$ErrorActionPreference = 'Stop'

# Resolve where this script lives so we can find the Dockerfile / compose file regardless
# of where the user invoked us from.
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = (Get-Location).Path

# 0. Help
function Show-CwcUsage {
    Write-Host ""
    Write-Host "cwc — claude-win-container launcher" -ForegroundColor Cyan
    Write-Host "Sandboxed Claude Code in a Windows container, scoped to the current directory."
    Write-Host ""
    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host "  cwc [flags] [command [args...]]"
    Write-Host ""
    Write-Host "COMMANDS" -ForegroundColor Yellow
    Write-Host "  (no args)                Run ``claude`` inside the container."
    Write-Host "  powershell               Drop to a PowerShell prompt inside the container."
    Write-Host "  mcp <subcommand>         Shorthand for ``cwc claude mcp ...`` (e.g. ``cwc mcp list``)."
    Write-Host "  firewall <subcommand>    Manage the LAN lockdown. Subcommands:"
    Write-Host "                             list                          show current state"
    Write-Host "                             allow <cidr>                  re-allow a subnet (e.g. 192.168.50.0/24)"
    Write-Host "                             deny <cidr>                   remove a previously allowed subnet"
    Write-Host "                             enable / disable              toggle the lockdown"
    Write-Host "                             host-list                     list FQDN -> target mappings"
    Write-Host "                             host-add <fqdn> [target]      map an FQDN inside the container"
    Write-Host "                                                           (target defaults to host-gateway)"
    Write-Host "                             host-remove <fqdn>            remove a mapping"
    Write-Host "  mount <subcommand>       Manage extra bind mounts (Obsidian vaults, design specs, runbooks)."
    Write-Host "                             list                          show configured mounts"
    Write-Host "                             add <name> <path> [ro|rw]     mount path at C:\docs\<name> in the"
    Write-Host "                                                           container (readonly by default)"
    Write-Host "                             remove <name>                 remove a mount"
    Write-Host "  help                     Print this usage and exit (also -Help / -h)."
    Write-Host "  <anything else>          Run that command inside the container."
    Write-Host ""
    Write-Host "FLAGS" -ForegroundColor Yellow
    Write-Host "  -Help, -h                Print this usage and exit."
    Write-Host "  -Pull                    ``docker pull`` latest image, then launch."
    Write-Host "  -Build                   Build image from local Dockerfile (requires repo clone)."
    Write-Host "  -Force                   Skip the project-root heuristic."
    Write-Host "  --                       Everything after this is forwarded to ``claude`` verbatim."
    Write-Host ""
    Write-Host "ENVIRONMENT" -ForegroundColor Yellow
    Write-Host "  CWC_IMAGE                Pin a specific image (default: vinylflamingo/claude-win-container:latest)."
    Write-Host "  CWC_LOCKDOWN_LAN=0       Disable the LAN-egress lockdown."
    Write-Host "  CWC_ALLOW_NETS=cidr,...  Re-allow specific subnets (e.g. ``192.168.50.0/24``)."
    Write-Host ""
    Write-Host "STATE" -ForegroundColor Yellow
    Write-Host "  %USERPROFILE%\.claude-win-container\auth\                 # shared auth (OAuth, API keys)"
    Write-Host "  %USERPROFILE%\.claude-win-container\projects\<slug>\      # per-project (memory, sessions)"
    Write-Host ""
    Write-Host "DOCS" -ForegroundColor Yellow
    Write-Host "  https://github.com/vinylflamingo/claude-win-container"
    Write-Host "  docs/per-project-setup.md   .mcp.json + .env forwarding rules"
    Write-Host "  docs/firewall.md            LAN lockdown details and overrides"
    Write-Host ""
}

if ($Help -or ($Cmd -and $Cmd.Count -gt 0 -and $Cmd[0] -eq 'help')) {
    Show-CwcUsage
    exit 0
}

# 0b. User config (persistent CWC settings)
# Stored at %USERPROFILE%\.cwc\config.json. Currently holds firewall preferences (lockdown
# on/off, persistent allow-list of CIDRs). Project-level .env overrides win at session time.
$cwcConfigDir  = Join-Path $env:USERPROFILE '.cwc'
$cwcConfigPath = Join-Path $cwcConfigDir 'config.json'

function Read-CwcConfig {
    if (-not (Test-Path $cwcConfigPath)) {
        return [pscustomobject]@{
            lockdown_lan = $true
            allow_nets   = @()
            extra_hosts  = @{}
            mounts       = @{}
        }
    }
    $raw = Get-Content -LiteralPath $cwcConfigPath -Raw
    $json = $raw | ConvertFrom-Json
    # JSON objects deserialise to PSCustomObject; convert nested ones to hashtables for mutation
    $hosts = @{}
    if ($json.extra_hosts) {
        foreach ($p in $json.extra_hosts.PSObject.Properties) { $hosts[$p.Name] = [string]$p.Value }
    }
    $mounts = @{}
    if ($json.mounts) {
        foreach ($p in $json.mounts.PSObject.Properties) {
            $m = $p.Value
            $mounts[$p.Name] = @{
                source   = [string]$m.source
                target   = [string]$m.target
                readonly = if ($null -ne $m.readonly) { [bool]$m.readonly } else { $true }
            }
        }
    }
    return [pscustomobject]@{
        lockdown_lan = if ($null -ne $json.lockdown_lan) { [bool]$json.lockdown_lan } else { $true }
        allow_nets   = @($json.allow_nets) | Where-Object { $_ }
        extra_hosts  = $hosts
        mounts       = $mounts
    }
}

function Write-CwcConfig($cfg) {
    if (-not (Test-Path $cwcConfigDir)) { New-Item -ItemType Directory -Force -Path $cwcConfigDir | Out-Null }
    @{
        lockdown_lan = [bool]$cfg.lockdown_lan
        allow_nets   = @($cfg.allow_nets)
        extra_hosts  = $cfg.extra_hosts
        mounts       = $cfg.mounts
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cwcConfigPath
}

# 0c. `cwc firewall ...` subcommand
# Persistent user-wide config; doesn't require a project directory or a running container.
if ($Cmd -and $Cmd.Count -gt 0 -and $Cmd[0] -eq 'firewall') {
    $sub = if ($Cmd.Count -ge 2) { $Cmd[1] } else { 'list' }
    $arg = if ($Cmd.Count -ge 3) { $Cmd[2] } else { $null }
    $cfg = Read-CwcConfig

    switch ($sub) {
        'list' {
            $state = if ($cfg.lockdown_lan) { 'enabled' } else { 'disabled' }
            Write-Host ""
            Write-Host "  LAN lockdown : $state" -ForegroundColor Cyan
            Write-Host "  Allow-list   : $(if ($cfg.allow_nets.Count) { $cfg.allow_nets -join ', ' } else { '(none)' })"
            if (@($cfg.extra_hosts.Keys).Count -gt 0) {
                Write-Host "  Host mappings:"
                foreach ($fqdn in ($cfg.extra_hosts.Keys | Sort-Object)) {
                    Write-Host "    $fqdn -> $($cfg.extra_hosts[$fqdn])"
                }
            } else {
                Write-Host "  Host mappings: (none)"
            }
            Write-Host "  Config file  : $cwcConfigPath"
            Write-Host ""
            Write-Host "  Project .env may override per-session via CWC_LOCKDOWN_LAN / CWC_ALLOW_NETS." -ForegroundColor DarkGray
            Write-Host ""
        }
        'allow' {
            if (-not $arg) { Write-Host "Usage: cwc firewall allow <cidr>" -ForegroundColor Red; exit 1 }
            if ($cfg.allow_nets -notcontains $arg) {
                $cfg.allow_nets = @($cfg.allow_nets) + $arg
                Write-CwcConfig $cfg
                Write-Host "Allowed: $arg" -ForegroundColor Green
            } else {
                Write-Host "$arg already in allow-list." -ForegroundColor DarkGray
            }
        }
        'deny' {
            if (-not $arg) { Write-Host "Usage: cwc firewall deny <cidr>" -ForegroundColor Red; exit 1 }
            $before = @($cfg.allow_nets).Count
            $cfg.allow_nets = @($cfg.allow_nets | Where-Object { $_ -ne $arg })
            if (@($cfg.allow_nets).Count -lt $before) {
                Write-CwcConfig $cfg
                Write-Host "Removed: $arg" -ForegroundColor Yellow
            } else {
                Write-Host "$arg was not in allow-list." -ForegroundColor DarkGray
            }
        }
        'enable' {
            $cfg.lockdown_lan = $true
            Write-CwcConfig $cfg
            Write-Host "LAN lockdown enabled." -ForegroundColor Green
        }
        'disable' {
            $cfg.lockdown_lan = $false
            Write-CwcConfig $cfg
            Write-Host "LAN lockdown disabled." -ForegroundColor Yellow
        }
        'host-list' {
            Write-Host ""
            if (@($cfg.extra_hosts.Keys).Count -gt 0) {
                Write-Host "  Host mappings:" -ForegroundColor Cyan
                foreach ($fqdn in ($cfg.extra_hosts.Keys | Sort-Object)) {
                    Write-Host "    $fqdn -> $($cfg.extra_hosts[$fqdn])"
                }
            } else {
                Write-Host "  (no host mappings)" -ForegroundColor DarkGray
            }
            Write-Host ""
        }
        'host-add' {
            if (-not $arg) {
                Write-Host "Usage: cwc firewall host-add <fqdn> [ip|host-gateway]" -ForegroundColor Red
                Write-Host "  Default target is 'host-gateway' (the Docker host's vNIC)."
                exit 1
            }
            $target = if ($Cmd.Count -ge 4) { $Cmd[3] } else { 'host-gateway' }
            $cfg.extra_hosts[$arg] = $target
            Write-CwcConfig $cfg
            Write-Host "Mapped: $arg -> $target" -ForegroundColor Green
            if ($target -ne 'host-gateway') {
                # Best-effort sanity check: warn if target IP is RFC1918 and not in allow_nets
                if ($target -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' -and
                    -not ($cfg.allow_nets | Where-Object { $target -like ($_ -replace '/.+$','') + '*' })) {
                    Write-Host "  Note: $target is in a private range. The lockdown will block it" -ForegroundColor Yellow
                    Write-Host "  unless you also run: cwc firewall allow <containing CIDR>" -ForegroundColor Yellow
                }
            }
        }
        'host-remove' {
            if (-not $arg) { Write-Host "Usage: cwc firewall host-remove <fqdn>" -ForegroundColor Red; exit 1 }
            if ($cfg.extra_hosts.ContainsKey($arg)) {
                $cfg.extra_hosts.Remove($arg)
                Write-CwcConfig $cfg
                Write-Host "Removed: $arg" -ForegroundColor Yellow
            } else {
                Write-Host "$arg was not mapped." -ForegroundColor DarkGray
            }
        }
        default {
            Write-Host "Unknown firewall subcommand: $sub" -ForegroundColor Red
            Write-Host "Usage: cwc firewall {list|allow <cidr>|deny <cidr>|enable|disable|host-list|host-add <fqdn> [ip]|host-remove <fqdn>}"
            exit 1
        }
    }
    exit 0
}

# `cwc mount ...` subcommand. Manages persistent additional bind-mounts (e.g. an Obsidian
# vault, design-spec folder, runbooks). Source paths are mounted into the container at
# C:\docs\<name> by default; readonly is the default. Stored alongside firewall config.
if ($Cmd -and $Cmd.Count -gt 0 -and $Cmd[0] -eq 'mount') {
    $sub = if ($Cmd.Count -ge 2) { $Cmd[1] } else { 'list' }
    $cfg = Read-CwcConfig
    if (-not $cfg.mounts) { $cfg.mounts = @{} }

    $reservedNames = @('workspace','claude-data','command-history','claude-auth')

    switch ($sub) {
        'list' {
            Write-Host ""
            if (@($cfg.mounts.Keys).Count -gt 0) {
                Write-Host "  Bind mounts:" -ForegroundColor Cyan
                foreach ($name in ($cfg.mounts.Keys | Sort-Object)) {
                    $m = $cfg.mounts[$name]
                    $mode = if ($m.readonly) { 'RO' } else { 'RW' }
                    $exists = if (Test-Path -LiteralPath $m.source) { '' } else { ' (MISSING)' }
                    Write-Host "    $name  [$mode]  $($m.source) -> $($m.target)$exists"
                }
            } else {
                Write-Host "  (no bind mounts configured)" -ForegroundColor DarkGray
            }
            Write-Host ""
        }
        'add' {
            $name   = if ($Cmd.Count -ge 3) { $Cmd[2] } else { $null }
            $source = if ($Cmd.Count -ge 4) { $Cmd[3] } else { $null }
            $mode   = if ($Cmd.Count -ge 5) { $Cmd[4].ToLower() } else { 'ro' }
            if (-not $name -or -not $source) {
                Write-Host "Usage: cwc mount add <name> <host-path> [ro|rw]" -ForegroundColor Red
                Write-Host "  Default mode is 'ro' (readonly). Container path defaults to C:\docs\<name>."
                exit 1
            }
            if ($name -match '[^a-zA-Z0-9._-]') {
                Write-Host "Mount name must be alphanumeric (with . _ - allowed). Got: $name" -ForegroundColor Red; exit 1
            }
            if ($reservedNames -contains $name.ToLower()) {
                Write-Host "'$name' is reserved (conflicts with built-in container path)." -ForegroundColor Red; exit 1
            }
            if ($mode -ne 'ro' -and $mode -ne 'rw') {
                Write-Host "Mode must be 'ro' or 'rw'. Got: $mode" -ForegroundColor Red; exit 1
            }
            if (-not (Test-Path -LiteralPath $source)) {
                Write-Host "Warning: source path doesn't exist: $source" -ForegroundColor Yellow
                Write-Host "  Adding anyway. The mount will be skipped at session start until the path exists." -ForegroundColor DarkGray
            } else {
                $source = (Resolve-Path -LiteralPath $source).Path
            }
            $cfg.mounts[$name] = @{
                source   = $source
                target   = "C:\docs\$name"
                readonly = ($mode -eq 'ro')
            }
            Write-CwcConfig $cfg
            $modeLabel = if ($mode -eq 'ro') { 'readonly' } else { 'writable' }
            Write-Host "Added: $name  [$modeLabel]  $source -> C:\docs\$name" -ForegroundColor Green
        }
        'remove' {
            $name = if ($Cmd.Count -ge 3) { $Cmd[2] } else { $null }
            if (-not $name) { Write-Host "Usage: cwc mount remove <name>" -ForegroundColor Red; exit 1 }
            if ($cfg.mounts.ContainsKey($name)) {
                $cfg.mounts.Remove($name)
                Write-CwcConfig $cfg
                Write-Host "Removed: $name" -ForegroundColor Yellow
            } else {
                Write-Host "'$name' is not configured." -ForegroundColor DarkGray
            }
        }
        default {
            Write-Host "Unknown mount subcommand: $sub" -ForegroundColor Red
            Write-Host "Usage: cwc mount {list|add <name> <host-path> [ro|rw]|remove <name>}"
            exit 1
        }
    }
    exit 0
}

# 1. Sanity checks
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "  docker not found on PATH." -ForegroundColor Red
    Write-Host "  Install Docker Desktop (Windows containers mode) and retry."
    Write-Host ""
    exit 1
}

# Project-root heuristic: looks like a real project unless -Force.
if (-not $Force) {
    $isProjectRoot = (Test-Path '.git') -or (Test-Path 'package.json') -or `
                     (Test-Path '*.sln') -or (Test-Path '.mcp.json') -or `
                     (Test-Path 'pyproject.toml') -or (Test-Path 'go.mod') -or `
                     (Test-Path 'Cargo.toml')
    if (-not $isProjectRoot) {
        Write-Host ""
        Write-Host "  '$projectDir' doesn't look like a project root." -ForegroundColor Yellow
        Write-Host "  (no .git, package.json, .sln, .mcp.json, pyproject.toml, go.mod, Cargo.toml)"
        Write-Host "  Use -Force if you really want to launch here."
        Write-Host ""
        exit 1
    }
}

# 2. Resolve per-project state directory
function Get-ProjectSlug([string]$path) {
    $abs = (Resolve-Path $path).Path.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($abs)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $hash = $sha1.ComputeHash($bytes)
    $sha1.Dispose()
    $hex = [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    $base = Split-Path -Leaf $abs
    # Strip any chars that aren't filesystem-safe.
    $base = ($base -replace '[^a-z0-9._-]', '-')
    return "$base-$($hex.Substring(0,12))"
}

$slug = Get-ProjectSlug $projectDir
$stateRoot = Join-Path $env:USERPROFILE '.claude-win-container'
$authDir   = Join-Path $stateRoot 'auth'
$projDir   = Join-Path $stateRoot "projects\$slug"
$cfgDir    = Join-Path $projDir   'config'
$histDir   = Join-Path $projDir   'history'

foreach ($dir in @($authDir, $cfgDir, $histDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

# 3. Build compose args
$composeFile = Join-Path $scriptRoot 'docker-compose.yml'
if (-not (Test-Path $composeFile)) {
    Write-Host "  docker-compose.yml not found at $composeFile" -ForegroundColor Red
    exit 1
}
$composeArgs = @('-f', $composeFile)

# 3b. Per-project overlay
# A project can ship claude-sandbox.overlay.yml in its root for project-specific extras
# (network attach, extra mounts, extra_hosts, etc.). Auto-included when present.
$projectOverlay = Join-Path $projectDir 'claude-sandbox.overlay.yml'
if (Test-Path $projectOverlay) {
    $composeArgs += '-f', $projectOverlay
    Write-Host "Using project overlay: $projectOverlay" -ForegroundColor DarkGray
}

# 4. Set env that compose will interpolate
# These are read by docker-compose.yml's variable substitution; they don't leak into the container.
$env:CLAUDE_WORKSPACE     = $projectDir
$env:CLAUDE_STATE_CONFIG  = $cfgDir
$env:CLAUDE_STATE_HISTORY = $histDir
$env:CLAUDE_STATE_AUTH    = $authDir

# 4a. Apply user config (~/.cwc/config.json) to the firewall env vars
# Project-level shell env / .env values still win — this only fills in the gaps.
$cwcCfg = Read-CwcConfig
if (-not $env:CWC_LOCKDOWN_LAN) {
    $env:CWC_LOCKDOWN_LAN = if ($cwcCfg.lockdown_lan) { '1' } else { '0' }
}
if (@($cwcCfg.allow_nets).Count -gt 0) {
    $existing = if ($env:CWC_ALLOW_NETS) { $env:CWC_ALLOW_NETS.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { @() }
    $merged = @($existing + $cwcCfg.allow_nets) | Select-Object -Unique
    $env:CWC_ALLOW_NETS = $merged -join ','
}

# Pass extra_hosts to the entrypoint via CWC_EXTRA_HOSTS env var. The entrypoint writes
# them to the container's hosts file at startup, resolving `host-gateway` itself (compose's
# host-gateway magic doesn't work reliably in `docker compose run`, but `host.docker.internal`
# always resolves correctly from inside the container, so the entrypoint uses that).
# Format: "fqdn:target,fqdn:target" — same syntax as Docker's --add-host.
$hostSummary = @()
if (@($cwcCfg.extra_hosts.Keys).Count -gt 0) {
    $pairs = foreach ($fqdn in $cwcCfg.extra_hosts.Keys) {
        $target = $cwcCfg.extra_hosts[$fqdn]
        $hostSummary += "$fqdn -> $target"
        "${fqdn}:${target}"
    }
    $env:CWC_EXTRA_HOSTS = $pairs -join ','
}

# Build --volume flags for additional bind mounts (Obsidian vault, design specs, etc.).
# Skips mounts whose source has gone missing — warns but doesn't fail the session.
$mountFlags = @()
$mountSummary = @()
if (@($cwcCfg.mounts.Keys).Count -gt 0) {
    foreach ($name in $cwcCfg.mounts.Keys) {
        $m = $cwcCfg.mounts[$name]
        if (-not (Test-Path -LiteralPath $m.source)) {
            Write-Host "  Skipping mount '$name': source not found ($($m.source))" -ForegroundColor Yellow
            continue
        }
        $opts = if ($m.readonly) { ':ro' } else { '' }
        $mountFlags += @('--volume', "$($m.source):$($m.target)$opts")
        $mountSummary += "$name -> $($m.target)$(if ($m.readonly) { ' (RO)' } else { ' (RW)' })"
    }
}

# 4b. Forward env vars from project's .env
# Allowlist:
#   - ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN  (auth — used by Claude itself)
#   - any key prefixed CLAUDE_*                   (consumer-defined Claude config)
#   - any key referenced as ${KEY} in .mcp.json   (MCP server runtime config)
# We do NOT forward arbitrary keys — the project's .env may contain DB passwords, etc.
function Read-DotEnv([string]$path) {
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    foreach ($raw in Get-Content -LiteralPath $path) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $line.Substring(0, $eq).Trim()
        $v = $line.Substring($eq + 1).Trim()
        # Strip surrounding quotes
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or
            ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $map[$k] = $v
    }
    return $map
}

function Get-McpReferencedKeys([string]$mcpPath) {
    if (-not (Test-Path $mcpPath)) { return @() }
    $text = Get-Content -LiteralPath $mcpPath -Raw
    $keys = @{}
    foreach ($m in [regex]::Matches($text, '\$\{([A-Z_][A-Z0-9_]*)(:-[^}]*)?\}')) {
        $keys[$m.Groups[1].Value] = $true
    }
    return $keys.Keys
}

$dotenv = Read-DotEnv (Join-Path $projectDir '.env')
$mcpKeys = @(Get-McpReferencedKeys (Join-Path $projectDir '.mcp.json'))

$forwardKeys = New-Object System.Collections.Generic.HashSet[string]
[void]$forwardKeys.Add('ANTHROPIC_API_KEY')
[void]$forwardKeys.Add('CLAUDE_CODE_OAUTH_TOKEN')
[void]$forwardKeys.Add('CWC_LOCKDOWN_LAN')
[void]$forwardKeys.Add('CWC_ALLOW_NETS')
[void]$forwardKeys.Add('CWC_EXTRA_HOSTS')
foreach ($k in $dotenv.Keys) {
    if ($k -like 'CLAUDE_*' -or $k -like 'ANTHROPIC_*' -or $k -like 'CWC_*') {
        [void]$forwardKeys.Add($k)
    }
}
foreach ($k in $mcpKeys) { [void]$forwardKeys.Add($k) }

# Build the -e flag list. Pull values from .env first, fall back to current process env.
$forwardFlags = @()
$forwardedSummary = @()
foreach ($k in $forwardKeys) {
    $v = $null
    if ($dotenv.ContainsKey($k)) { $v = $dotenv[$k] }
    elseif (Test-Path "Env:$k")  { $v = (Get-Item "Env:$k").Value }
    if ($null -ne $v -and $v -ne '') {
        $forwardFlags += @('-e', "$k=$v")
        # Mask secrets in the summary print.
        $masked = if ($k -match 'KEY|TOKEN|SECRET|PASSWORD') { '***' } else { $v }
        $forwardedSummary += "$k=$masked"
    }
}

# 5. Acquire image: pull (default) or build (when -Build or no Dockerfile beside us)
# Image reference can be overridden via CWC_IMAGE; default points at the public Docker Hub repo.
$cwcImage = if ($env:CWC_IMAGE) { $env:CWC_IMAGE } else { 'vinylflamingo/claude-win-container:latest' }
$env:CWC_IMAGE = $cwcImage   # surface to compose interpolation

docker image inspect $cwcImage *> $null
$imageMissing = ($LASTEXITCODE -ne 0)
$haveLocalDockerfile = Test-Path (Join-Path $scriptRoot 'Dockerfile')

if ($Build) {
    if (-not $haveLocalDockerfile) {
        throw "-Build requires a local Dockerfile next to cwc.ps1. Clone https://github.com/vinylflamingo/claude-win-container or drop -Build to pull from Docker Hub."
    }
    Write-Host "Building $cwcImage from local Dockerfile (first run ~5-10 min)..." -ForegroundColor Cyan
    & docker compose @composeArgs build claude-code
    if ($LASTEXITCODE -ne 0) { throw "docker compose build failed" }
} elseif ($Pull -or $imageMissing) {
    if ($imageMissing) {
        Write-Host "Image $cwcImage not found locally — pulling from Docker Hub..." -ForegroundColor Cyan
    } else {
        Write-Host "Pulling $cwcImage..." -ForegroundColor Cyan
    }
    & docker pull $cwcImage
    if ($LASTEXITCODE -ne 0) {
        if ($haveLocalDockerfile) {
            Write-Host "Pull failed — falling back to local build." -ForegroundColor Yellow
            & docker compose @composeArgs build claude-code
            if ($LASTEXITCODE -ne 0) { throw "docker compose build (fallback) failed" }
        } else {
            throw "docker pull failed and no local Dockerfile available to build from."
        }
    }
}

# 6. Resolve command
# Default: run `claude`. Convenience: `cwc mcp ...` is shorthand for `cwc claude mcp ...`
# (saves users from typing `claude` for the most common subcommand pass-through).
if (-not $Cmd -or $Cmd.Count -eq 0) {
    $Cmd = @('claude')
} elseif ($Cmd[0] -eq 'mcp') {
    $Cmd = @('claude') + $Cmd
}

# 7. Print session summary
Write-Host ""
Write-Host "  Project   : $projectDir" -ForegroundColor DarkGray
Write-Host "  State     : $projDir" -ForegroundColor DarkGray
Write-Host "  Auth      : $authDir" -ForegroundColor DarkGray
Write-Host "  Command   : $($Cmd -join ' ')" -ForegroundColor DarkGray
if ($forwardedSummary.Count -gt 0) {
    Write-Host "  Forwarded : $($forwardedSummary -join ', ')" -ForegroundColor DarkGray
}
if ($hostSummary.Count -gt 0) {
    Write-Host "  Hosts     : $($hostSummary -join ', ')" -ForegroundColor DarkGray
}
if ($mountSummary.Count -gt 0) {
    Write-Host "  Mounts    : $($mountSummary -join ', ')" -ForegroundColor DarkGray
}
Write-Host ""

# 8. Launch
& docker compose @composeArgs run --rm @forwardFlags @mountFlags claude-code @Cmd
exit $LASTEXITCODE
