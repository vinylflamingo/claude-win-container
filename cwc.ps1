# cwc.ps1 -- claude-win-container launcher.
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
#   $env:CWC_IMAGE = 'fcostoya/claude-win-container:0.1.1'   # pin a version
#   default = 'fcostoya/claude-win-container:latest'
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
    Write-Host "cwc -- claude-win-container launcher" -ForegroundColor Cyan
    Write-Host "Sandboxed Claude Code in a Windows container, scoped to the current directory."
    Write-Host ""
    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host "  cwc [flags] [command [args...]]"
    Write-Host ""
    Write-Host "COMMANDS" -ForegroundColor Yellow
    Write-Host "  (no args)                Run ``claude`` inside the container."
    Write-Host "  setup                    First-time wizard for this project. Configures firewall,"
    Write-Host "                           host-services, mounts, and harden for the current dir."
    Write-Host "                           Run before the first ``cwc`` invocation in any new project."
    Write-Host "  dev [args...]            Session-scoped dev mode. Runs against the local :dev image"
    Write-Host "                           (built from the Dockerfile next to cwc.ps1). Each ``cwc dev``"
    Write-Host "                           explicitly opts in -- normal ``cwc`` stays unaffected."
    Write-Host "                             dev build / rebuild / clean   manage the :dev image"
    Write-Host "                             dev status                    show :dev image state + flags"
    Write-Host "                             dev flag {list|set|unset}     persistent dev flags"
    Write-Host "                                                           (e.g. live_entrypoint_mount)"
    Write-Host "  powershell               Drop to a PowerShell prompt inside the container."
    Write-Host "  mcp <subcommand>         Shorthand for ``cwc claude mcp ...`` (e.g. ``cwc mcp list``)."
    Write-Host "  firewall <subcommand>    Per-project. Manage this project's LAN lockdown:"
    Write-Host "                             list                          show current state"
    Write-Host "                             allow <cidr>                  re-allow a subnet (e.g. 192.168.50.0/24)"
    Write-Host "                             deny <cidr>                   remove a previously allowed subnet"
    Write-Host "                             enable / disable              toggle the lockdown"
    Write-Host "                             host-list                     list FQDN -> target mappings"
    Write-Host "                             host-add <fqdn> [target]      map an FQDN inside the container"
    Write-Host "                                                           (target defaults to host-gateway)"
    Write-Host "                             host-remove <fqdn>            remove a mapping"
    Write-Host "                             denylist {list|add|remove|reset}"
    Write-Host "                                                           GLOBAL -- FQDNs that host-add refuses"
    Write-Host "                                                           (defaults: anthropic.com / claude.ai etc.)"
    Write-Host "  mount <subcommand>       Per-project. Bind mounts (Obsidian vaults, design specs, runbooks)."
    Write-Host "                             list                          show configured mounts"
    Write-Host "                             add <name> <path> [ro|rw]     mount path at C:\docs\<name> in the"
    Write-Host "                                                           container (readonly by default)"
    Write-Host "                             remove <name>                 remove a mount"
    Write-Host "  trust                    Trust the current state of policy files in this project"
    Write-Host "                           (claude-sandbox.overlay.yml, .env, .mcp.json). Required when"
    Write-Host "                           any of these change between sessions."
    Write-Host "  trust list               Show trust state for tracked files in this project."
    Write-Host "  untrust                  Remove trust for this project (next 'cwc' will re-prompt)."
    Write-Host "  auth reset               Wipe shared auth (~/.claude-win-container/auth/) -- re-auth"
    Write-Host "                           on next run. Per-project state is unaffected."
    Write-Host "  auth where               Print where shared and per-project state live."
    Write-Host "  harden {enable|disable|status}"
    Write-Host "                           Per-project. Toggle the tamper-resistant in-container"
    Write-Host "                           watchdog. Off by default; run 'cwc harden status' for what"
    Write-Host "                           it does and the trade-offs (also docs/security.md)."
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
    Write-Host "  CWC_IMAGE                Pin a specific image (default: fcostoya/claude-win-container:latest)."
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
# Two layers:
#   ~/.cwc/config.json                 -- global security policy (denylist + defaults).
#                                         Things the user should not be able to weaken
#                                         per-project (denylist) or that act as system-wide
#                                         defaults applied when a project doesn't override.
#   ~/.cwc/projects/<slug>/config.json -- per-project sandbox config (firewall, mounts,
#                                         host-services, harden, trusted-file hashes).
#                                         Lives outside the workspace so the agent can't
#                                         see or modify it. <slug> = Get-ProjectSlug of
#                                         the project's absolute path -- stable across
#                                         runs, unique per project.
$cwcConfigDir   = Join-Path $env:USERPROFILE '.cwc'
$cwcConfigPath  = Join-Path $cwcConfigDir 'config.json'
$cwcProjectsDir = Join-Path $cwcConfigDir 'projects'

# Dev-mode state. Session-scoped: each `cwc dev` invocation explicitly opts in;
# leaving the session puts you back in normal mode. Flag settings (e.g.
# live_entrypoint_mount) ARE persistent so you don't have to re-set them every
# session -- they live at ~/.cwc/dev.json and are read at the start of each
# dev invocation.
$cwcDevImage      = 'fcostoya/claude-win-container:dev'
$cwcDevConfigPath = Join-Path $cwcConfigDir 'dev.json'
$script:cwcDevMode         = $false
$script:cwcDevExtraMounts  = @()

# Hostname / target validators. Used by both `cwc firewall host-add` (block bad input
# at config-write time) and the entrypoint (defense in depth -- refuse bad entries
# at hosts-file-write time even if config was hand-edited). Keep entrypoint.ps1
# in sync with these -- they're duplicated there because entrypoint runs in a
# different process inside the container.
$script:cwcFqdnRegex = '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'

function Test-CwcFqdn([string]$fqdn) {
    if (-not $fqdn) { return $false }
    if ($fqdn.Length -gt 253) { return $false }
    return $fqdn.ToLowerInvariant() -match $script:cwcFqdnRegex
}

function Test-CwcHostTarget([string]$target) {
    if (-not $target) { return $false }
    if ($target -eq 'host-gateway') { return $true }
    if ($target -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $octets = $target.Split('.') | ForEach-Object { [int]$_ }
        return -not ($octets | Where-Object { $_ -gt 255 })
    }
    # IPv6: loose check (contains a colon, only hex/colons)
    if ($target -match '^[0-9a-fA-F:]+$' -and $target.Contains(':')) { return $true }
    return $false
}

# Default denylist for `cwc firewall host-add`. These cover Anthropic's auth-bearing
# channels -- redirecting them via hosts-file injection would let an agent (or careless
# `.env`) MITM the API key / OAuth token. Configurable via `cwc firewall denylist`.
function Get-CwcDefaultDenylist {
    return @(
        '*.anthropic.com', 'anthropic.com',
        '*.claude.ai',     'claude.ai',
        '*.claude.com',    'claude.com',
        '*.anthropic.ai',  'anthropic.ai'
    )
}

function Test-CwcFqdnDenied([string]$fqdn, [string[]]$denylist) {
    if (-not $fqdn) { return $false }
    $lower = $fqdn.ToLowerInvariant()
    foreach ($pattern in $denylist) {
        if (-not $pattern) { continue }
        $p = $pattern.ToLowerInvariant()
        if ($p.StartsWith('*.')) {
            $suffix = $p.Substring(2)
            if ($lower -eq $suffix -or $lower.EndsWith('.' + $suffix)) { return $true }
        } elseif ($lower -eq $p) {
            return $true
        }
    }
    return $false
}

# Stable per-project state slug. SHA-1 of the absolute path (case-insensitive),
# truncated to 12 chars and prefixed with the basename. Hoisted up to the helpers
# section so the trust subcommand and the main flow share one definition.
function Get-ProjectSlug([string]$path) {
    $abs = (Resolve-Path $path).Path.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($abs)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $hash = $sha1.ComputeHash($bytes)
    $sha1.Dispose()
    $hex = [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    $base = Split-Path -Leaf $abs
    $base = ($base -replace '[^a-z0-9._-]', '-')
    return "$base-$($hex.Substring(0,12))"
}

# Bundle the three pieces of project identity callers usually want at once.
# Use this instead of recomputing slug/name/path independently in different code paths.
function Get-CwcProjectMetadata([string]$projectDir) {
    $abs = (Resolve-Path $projectDir).Path
    return [pscustomobject]@{
        path = $abs
        name = Split-Path -Leaf $abs
        slug = Get-ProjectSlug $abs
    }
}

# Returns the absolute path to a project's config file given its slug.
# The file may not exist -- callers should check with Test-Path.
function Get-CwcProjectConfigPath([string]$slug) {
    return Join-Path $cwcProjectsDir (Join-Path $slug 'config.json')
}

# Trust system. The agent has RW on the workspace, so it can edit any file there
# -- including files we read at launcher start (compose overlay, .env forwarding,
# .mcp.json env-key references). Each of these files can expand what flows into
# the next session's container. The trust system tracks per-project SHA-256 of
# these files and refuses to launch when they change without explicit ack.
$script:cwcTrustedFileNames = @(
    'claude-sandbox.overlay.yml',
    '.env',
    '.mcp.json'
)

function Get-FileSha256([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    } catch { return $null }
}

# Returns a hashtable describing the trust state of all tracked files in a project.
# Used by both the trust subcommand and the pre-launch verification.
# $projectCfg is a per-project config (from Read-CwcProjectConfig); pass $null for
# "no project config yet" (everything will report as untrusted).
function Get-CwcProjectTrustState($projectCfg, [string]$projectDir) {
    $trustedMap = if ($projectCfg -and $projectCfg.trusted_files) { $projectCfg.trusted_files } else { @{} }
    $files = @()
    $anyChanged = $false
    $anyPresent = $false
    foreach ($name in $script:cwcTrustedFileNames) {
        $path = Join-Path $projectDir $name
        $exists = Test-Path -LiteralPath $path
        $current = if ($exists) { Get-FileSha256 $path } else { $null }
        $trusted = if ($trustedMap.ContainsKey($name)) { [string]$trustedMap[$name] } else { $null }
        $status = if (-not $exists -and -not $trusted) {
            'absent'
        } elseif (-not $exists -and $trusted) {
            'deleted'
        } elseif ($exists -and -not $trusted) {
            'untrusted'
        } elseif ($current -eq $trusted) {
            'trusted'
        } else {
            'modified'
        }
        $files += [pscustomobject]@{
            name         = $name
            path         = $path
            exists       = $exists
            current_hash = $current
            trusted_hash = $trusted
            status       = $status
        }
        if ($exists) { $anyPresent = $true }
        if ($status -in @('untrusted', 'modified', 'deleted')) { $anyChanged = $true }
    }
    return [pscustomobject]@{
        files       = $files
        any_changed = $anyChanged
        any_present = $anyPresent
        first_run   = ($trustedMap.Count -eq 0)
    }
}

# Computes current SHA-256s for all tracked files in the project and writes them
# into the project's config. Manages its own read-modify-write cycle so callers
# don't have to worry about stale config state. Auto-creates a default project
# config when the file doesn't exist yet (trust can be invoked before `cwc setup`,
# e.g. by a script).
function Save-CwcProjectTrust([string]$slug, [string]$projectDir) {
    $cfg = Read-CwcProjectConfig $slug
    if (-not $cfg) {
        $meta = Get-CwcProjectMetadata $projectDir
        $cfg = [pscustomobject]@{
            project_path   = $meta.path
            project_name   = $meta.name
            lockdown_lan   = $true
            harden_enabled = $false
            allow_nets     = @()
            extra_hosts    = @{}
            mounts         = @{}
            trusted_files  = @{}
        }
    }
    $map = @{}
    foreach ($name in $script:cwcTrustedFileNames) {
        $path = Join-Path $projectDir $name
        if (Test-Path -LiteralPath $path) {
            $hash = Get-FileSha256 $path
            if ($hash) { $map[$name] = $hash }
        }
    }
    $cfg.trusted_files = $map
    Write-CwcProjectConfig $slug $cfg
    return $map.Count
}

function Show-TrustState($state) {
    foreach ($f in $state.files) {
        $label = switch ($f.status) {
            'trusted'   { 'trusted ' }
            'untrusted' { 'NEW     ' }
            'modified'  { 'MODIFIED' }
            'deleted'   { 'DELETED ' }
            'absent'    { 'absent  ' }
        }
        $color = switch ($f.status) {
            'trusted'   { 'Green' }
            'untrusted' { 'Yellow' }
            'modified'  { 'Yellow' }
            'deleted'   { 'Red' }
            'absent'    { 'DarkGray' }
        }
        Write-Host ("    [{0}] {1}" -f $label, $f.name) -ForegroundColor $color
    }
}

# True iff stdin is hooked to a real console -- used to decide whether to prompt
# or fail-closed on a trust mismatch. Mirrors install.ps1's approach.
function Test-CwcInteractive {
    if (-not [Environment]::UserInteractive) { return $false }
    if ($Host.Name -eq 'Default Host') { return $false }
    if ([Console]::IsInputRedirected) { return $false }
    return $true
}

# Interactive helpers used by Invoke-CwcProjectSetup. Mirror install.ps1's helpers
# of the same shape -- intentional duplication; install.ps1 still has its own copy
# because it runs before cwc.ps1 is on disk.
function Read-CwcYesNo([string]$prompt, [bool]$default = $false) {
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

function Read-CwcNonEmpty([string]$prompt) {
    while ($true) {
        $resp = Read-Host $prompt
        if ($resp -and $resp.Trim()) { return $resp.Trim() }
        Write-Host "  Required." -ForegroundColor Yellow
    }
}

# --- Persistent config (split global / per-project) ---------------------------
# State is divided into:
#   global   -- security policy at ~/.cwc/config.json: host_denylist + defaults block.
#   project  -- everything else at ~/.cwc/projects/<slug>/config.json: lockdown_lan,
#               harden_enabled, allow_nets, extra_hosts, mounts, trusted_files.
# Read-CwcProjectConfig returns $null when the project has no config yet
# (signal for the auto-setup flow to kick in).

function Read-CwcGlobalConfig {
    if (-not (Test-Path $cwcConfigPath)) {
        return [pscustomobject]@{
            host_denylist = @(Get-CwcDefaultDenylist)
            defaults      = @{
                lockdown_lan   = $true
                harden_enabled = $false
            }
        }
    }
    $raw  = Get-Content -LiteralPath $cwcConfigPath -Raw
    $json = $raw | ConvertFrom-Json
    $denylist = if ($null -ne $json.host_denylist) {
        @($json.host_denylist) | Where-Object { $_ }
    } else {
        @(Get-CwcDefaultDenylist)
    }
    $defaults = @{
        lockdown_lan   = $true
        harden_enabled = $false
    }
    if ($json.defaults) {
        if ($null -ne $json.defaults.lockdown_lan)   { $defaults.lockdown_lan   = [bool]$json.defaults.lockdown_lan }
        if ($null -ne $json.defaults.harden_enabled) { $defaults.harden_enabled = [bool]$json.defaults.harden_enabled }
    }
    return [pscustomobject]@{
        host_denylist = $denylist
        defaults      = $defaults
    }
}

function Write-CwcGlobalConfig($cfg) {
    if (-not (Test-Path $cwcConfigDir)) { New-Item -ItemType Directory -Force -Path $cwcConfigDir | Out-Null }
    @{
        host_denylist = @($cfg.host_denylist)
        defaults      = @{
            lockdown_lan   = [bool]$cfg.defaults.lockdown_lan
            harden_enabled = [bool]$cfg.defaults.harden_enabled
        }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cwcConfigPath
}

function Read-CwcProjectConfig([string]$slug) {
    $path = Get-CwcProjectConfigPath $slug
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw  = Get-Content -LiteralPath $path -Raw
    $json = $raw | ConvertFrom-Json

    # extra_hosts: tolerate the old bare-string target format (one-line grandfather
    # to {target, ports = 443,80}). Per-project files are written by the new code
    # path so this only matters for hand-edited or migrated files.
    $hosts = @{}
    if ($json.extra_hosts) {
        foreach ($p in $json.extra_hosts.PSObject.Properties) {
            $val = $p.Value
            if ($val -is [string]) {
                $hosts[$p.Name] = @{ target = [string]$val; ports = @(443, 80) }
            } elseif ($val) {
                $portsRaw = if ($null -ne $val.ports) { @($val.ports) } else { @(443, 80) }
                $hosts[$p.Name] = @{
                    target = [string]$val.target
                    ports  = @($portsRaw | ForEach-Object { [int]$_ })
                }
            }
        }
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

    # trusted_files at the project level is a flat name -> sha256 map.
    # (The old global-config schema keyed it by slug; per-project files don't
    # need that indirection since the file itself is already slug-scoped.)
    $trustedFiles = @{}
    if ($json.trusted_files) {
        foreach ($p in $json.trusted_files.PSObject.Properties) {
            $trustedFiles[$p.Name] = [string]$p.Value
        }
    }

    $allowNets = if ($json.allow_nets) { @($json.allow_nets) | Where-Object { $_ } } else { @() }

    # Fall back to global defaults when project file omits a field. This lets the
    # global config drive the "what does cwc do by default everywhere" knob without
    # baking the value into every per-project file at write time.
    $global = Read-CwcGlobalConfig

    return [pscustomobject]@{
        project_path   = [string]$json.project_path
        project_name   = [string]$json.project_name
        lockdown_lan   = if ($null -ne $json.lockdown_lan)   { [bool]$json.lockdown_lan }   else { [bool]$global.defaults.lockdown_lan }
        harden_enabled = if ($null -ne $json.harden_enabled) { [bool]$json.harden_enabled } else { [bool]$global.defaults.harden_enabled }
        allow_nets     = @($allowNets)
        extra_hosts    = $hosts
        mounts         = $mounts
        trusted_files  = $trustedFiles
    }
}

function Write-CwcProjectConfig([string]$slug, $cfg) {
    $dir = Join-Path $cwcProjectsDir $slug
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $path = Join-Path $dir 'config.json'
    @{
        project_path   = [string]$cfg.project_path
        project_name   = [string]$cfg.project_name
        lockdown_lan   = [bool]$cfg.lockdown_lan
        harden_enabled = [bool]$cfg.harden_enabled
        allow_nets     = @($cfg.allow_nets)
        extra_hosts    = $cfg.extra_hosts
        mounts         = $cfg.mounts
        trusted_files  = if ($cfg.trusted_files) { $cfg.trusted_files } else { @{} }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path
}

# Dev-mode helpers ------------------------------------------------------------
# Known flags + their defaults. `cwc dev flag set/unset` validates against this
# list. Add new flags here; the dev session block below picks up known flags by
# name and applies them.
$script:cwcDevFlagDefaults = @{
    live_entrypoint_mount = $false
}

function Read-CwcDevConfig {
    $flags = @{}
    foreach ($k in $script:cwcDevFlagDefaults.Keys) {
        $flags[$k] = [bool]$script:cwcDevFlagDefaults[$k]
    }
    if (-not (Test-Path $cwcDevConfigPath)) { return $flags }
    $raw  = Get-Content -LiteralPath $cwcDevConfigPath -Raw
    $json = $raw | ConvertFrom-Json
    if ($json.flags) {
        foreach ($p in $json.flags.PSObject.Properties) {
            if ($script:cwcDevFlagDefaults.ContainsKey($p.Name)) {
                $flags[$p.Name] = [bool]$p.Value
            }
        }
    }
    return $flags
}

function Write-CwcDevConfig($flags) {
    if (-not (Test-Path $cwcConfigDir)) { New-Item -ItemType Directory -Force -Path $cwcConfigDir | Out-Null }
    @{ flags = $flags } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $cwcDevConfigPath
}

# True when cwc.ps1 is running from a git clone of this repo (Dockerfile + docker-
# compose.yml next to it). Required for `cwc dev` -- the published install drops
# only cwc.ps1 + docker-compose.yml + project-overlay; you can't build :dev without
# the Dockerfile.
function Test-CwcInClone {
    return (Test-Path (Join-Path $scriptRoot 'Dockerfile')) -and `
           (Test-Path (Join-Path $scriptRoot 'docker-compose.yml'))
}

# Image-tag classification + freshness helpers ---------------------------------
# Used by the launch banner. Pure tag parsing here; the GitHub-API "is this the
# latest stable?" lookup is a separate function with its own cache file.

# Repo coordinates for the GitHub releases API. Bake them in here so the version
# check works the same regardless of git remote / install path.
$script:cwcReleaseRepo  = 'vinylflamingo/claude-win-container'
$script:cwcVersionCache = Join-Path $cwcConfigDir 'version-cache.json'

function Get-CwcImageClassification([string]$image) {
    # Extract tag (everything after the last ':'). Default to 'latest' if no tag given.
    $tag = if ($image -match ':([^:]+)$') { $Matches[1] } else { 'latest' }

    if ($tag -eq 'dev') {
        return [pscustomobject]@{ kind = 'dev'; version = $null; tag = $tag }
    }
    if ($tag -eq 'latest' -or $tag -match '^latest(-ltsc\d+)?$') {
        return [pscustomobject]@{ kind = 'latest-tag'; version = $null; tag = $tag }
    }
    # Moving preview pointer (`:preview`, `:preview-ltsc2019`, `:preview-ltsc2022`).
    # No version info embedded -- the underlying build's version is whatever was
    # most recently pushed.
    if ($tag -eq 'preview' -or $tag -match '^preview(-ltsc\d+)?$') {
        return [pscustomobject]@{ kind = 'preview-moving'; version = $null; tag = $tag }
    }
    # Strip our base-image suffix (e.g. '0.1.1-ltsc2019' -> '0.1.1') so semver
    # comparisons work uniformly. CI publishes both base-suffixed and bare tags.
    $semverPart = $tag -replace '-ltsc\d+$', ''
    # SHA-pinned preview build (`0.1.1.d9cd72`, `0.1.1.d9cd72-ltsc2019`). CI's
    # current convention is 6 hex chars, but accept any hex sequence to stay
    # tolerant of future format changes.
    if ($semverPart -match '^(\d+\.\d+\.\d+)\.[0-9a-f]+$') {
        return [pscustomobject]@{ kind = 'preview-pinned'; version = $Matches[1]; tag = $tag }
    }
    # Legacy preview/prerelease semver segment: `0.1.1-rc.1`, `2.0.0-alpha`, etc.
    # Kept for backward compat -- the project's current preview convention is the
    # SHA-pinned form above, but third-party forks or older tags may use this.
    if ($semverPart -match '^(\d+\.\d+\.\d+)-(rc|alpha|beta|preview|pre)') {
        return [pscustomobject]@{ kind = 'preview-pinned'; version = $Matches[1]; tag = $tag }
    }
    if ($semverPart -match '^\d+\.\d+\.\d+$') {
        return [pscustomobject]@{ kind = 'stable'; version = $semverPart; tag = $tag }
    }
    return [pscustomobject]@{ kind = 'custom'; version = $null; tag = $tag }
}

# Returns the latest STABLE release version (e.g. '0.1.1') from GitHub, using a
# 24-hour file cache so we don't hit the API on every launch. Returns $null when
# offline / rate-limited / never-cached.
function Get-CwcLatestStableVersion {
    param([int]$CacheTtlHours = 24)

    $cached = $null
    if (Test-Path $script:cwcVersionCache) {
        try {
            $cached = Get-Content -LiteralPath $script:cwcVersionCache -Raw | ConvertFrom-Json
            if ($cached.checked_at -and $cached.latest_stable) {
                $age = (Get-Date) - [datetime]::Parse($cached.checked_at)
                if ($age.TotalHours -lt $CacheTtlHours) {
                    return [string]$cached.latest_stable
                }
            }
        } catch { $cached = $null }
    }

    # Cache stale or missing -- ask GitHub. /releases/latest excludes prereleases
    # by design, so the response is always a stable version.
    try {
        $url  = "https://api.github.com/repos/$($script:cwcReleaseRepo)/releases/latest"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 3 -Headers @{ 'User-Agent' = 'cwc' }
        $version = ([string]$resp.tag_name) -replace '^v', ''
        @{
            checked_at    = (Get-Date).ToUniversalTime().ToString('o')
            latest_stable = $version
        } | ConvertTo-Json | Set-Content -LiteralPath $script:cwcVersionCache
        return $version
    } catch {
        # Fall back to the (possibly stale) cached value rather than nothing.
        if ($cached -and $cached.latest_stable) { return [string]$cached.latest_stable }
        return $null
    }
}

# Heuristic project-root detection. The same checks are used by the main launcher
# flow before computing slug+state-dir, and by subcommands that refuse to operate
# outside a project. -Force on the launcher bypasses this; subcommands don't honor
# -Force because they don't need it (the user can always cd to the right dir).
function Test-CwcInProjectRoot {
    return (Test-Path '.git') -or (Test-Path 'package.json') -or `
           (Test-Path '*.sln') -or (Test-Path '.mcp.json') -or `
           (Test-Path 'pyproject.toml') -or (Test-Path 'go.mod') -or `
           (Test-Path 'Cargo.toml')
}

# Loads the project config or exits with an actionable error if it doesn't exist.
# Use this from subcommands that mutate per-project state. The main launcher flow
# calls Read-CwcProjectConfig directly so it can trigger the auto-setup wizard
# instead of bailing.
function Get-RequiredCwcProjectConfig([string]$slug, [string]$projectDir) {
    $cfg = Read-CwcProjectConfig $slug
    if (-not $cfg) {
        Write-Host ""
        Write-Host "  No cwc config for this project yet." -ForegroundColor Yellow
        Write-Host "  Run 'cwc setup' first (from $projectDir)." -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }
    return $cfg
}

# Project-scoped setup wizard. Walks the user through 6 questions and writes a
# per-project config to ~/.cwc/projects/<slug>/config.json. Used by:
#   - the explicit `cwc setup` subcommand (re-run to reconfigure a project)
#   - the main launcher flow (auto-triggered when no project config exists)
# Returns $true when a config was written, $false if the user bailed.
# REQUIRES an interactive session -- callers must check Test-CwcInteractive first
# (the auto-trigger does this and exits with a fail-closed message otherwise).
function Invoke-CwcProjectSetup([string]$projectDir, [string]$slug) {
    $meta = Get-CwcProjectMetadata $projectDir
    $existing = Read-CwcProjectConfig $slug

    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host "  cwc setup -- $($meta.name)" -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Project: $($meta.path)"
    Write-Host "  Config : $(Get-CwcProjectConfigPath $slug)" -ForegroundColor DarkGray
    Write-Host ""

    if ($existing) {
        Write-Host "  An existing config was found for this project:" -ForegroundColor Yellow
        Write-Host "    Lockdown   : $(if ($existing.lockdown_lan) { 'enabled' } else { 'disabled' })"
        Write-Host "    Allow CIDRs: $(if ($existing.allow_nets.Count) { ($existing.allow_nets) -join ', ' } else { '(none)' })"
        if (@($existing.extra_hosts.Keys).Count -gt 0) {
            $hostList = foreach ($k in $existing.extra_hosts.Keys) { "$k -> $($existing.extra_hosts[$k].target)" }
            Write-Host "    Host maps  : $($hostList -join '; ')"
        }
        Write-Host "    Harden     : $(if ($existing.harden_enabled) { 'enabled' } else { 'disabled' })"
        Write-Host ""
        if (-not (Read-CwcYesNo "  Reconfigure (this replaces the existing project config)?" $false)) {
            Write-Host "  Keeping existing config." -ForegroundColor DarkGray
            Write-Host ""
            return $false
        }
        Write-Host ""
    }

    Write-Host "  Answer these questions to set up the sandbox for THIS project."
    Write-Host "  Press Enter at any [y/N] to accept the default. Change anything later"
    Write-Host "  with 'cwc firewall ...', 'cwc mount ...', or 'cwc harden ...'."
    Write-Host ""

    $cfg = [pscustomobject]@{
        project_path   = $meta.path
        project_name   = $meta.name
        lockdown_lan   = $true
        harden_enabled = $false
        allow_nets     = @()
        extra_hosts    = @{}
        mounts         = @{}
        trusted_files  = if ($existing -and $existing.trusted_files) { $existing.trusted_files } else { @{} }
    }

    # Q1 -- public internet (informational)
    Write-Host "1. Public internet (Anthropic API, npm registry, GitHub):" -ForegroundColor Green
    Write-Host "   Always allowed. Required for Claude to function."
    Write-Host ""

    # Q2 -- LAN subnets
    Write-Host "2. LAN services" -ForegroundColor Green
    Write-Host "   Examples: a network printer at 192.168.1.50, a NAS at 10.0.0.5,"
    Write-Host "   another machine on your dev network."
    if (Read-CwcYesNo "   Do you need to reach any LAN subnets?") {
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
            $cfg.allow_nets += $cidr
            Write-Host "     OK added $cidr" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # Q3 -- host services with port list + canonical 'host' alias + optional extras
    Write-Host "3. Services on your Docker host" -ForegroundColor Green
    Write-Host "   Examples: a Next.js / Vite dev server on :3000, Traefik on :443,"
    Write-Host "   a local Postgres on :5432, an SSH tunnel on :22. The agent reaches"
    Write-Host "   them as http://host:<port> from inside the container."
    if (Read-CwcYesNo "   Do you need to reach any?") {
        Write-Host "   Enter a comma-separated list of TCP ports to expose:"
        Write-Host "     80, 443           (HTTP/HTTPS - reverse proxy / API gateway)"
        Write-Host "     3000, 5173, 8080  (typical dev servers)"
        Write-Host "     22, 5432          (SSH, Postgres)"
        $ports = @()
        while ($true) {
            $portsRaw = Read-Host "     Ports (comma-separated)"
            if (-not $portsRaw -or -not $portsRaw.Trim()) {
                Write-Host "     Required (or answer no above to skip this step)." -ForegroundColor Yellow
                continue
            }
            $ports = @()
            $bad = $false
            foreach ($p in $portsRaw.Split(',')) {
                $p = $p.Trim()
                if (-not $p) { continue }
                $parsed = 0
                if (-not [int]::TryParse($p, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) {
                    Write-Host "     Invalid port '$p' (must be 1-65535). Try again." -ForegroundColor Yellow
                    $bad = $true
                    break
                }
                $ports += $parsed
            }
            if (-not $bad -and $ports.Count -gt 0) { break }
        }

        # Canonical 'host' alias is what we tell agents to use, so it's always present
        # whenever Q3 is enabled.
        $cfg.extra_hosts['host'] = @{ target = 'host-gateway'; ports = $ports }
        Write-Host "     OK host -> host-gateway  ports=$($ports -join ',')" -ForegroundColor DarkGray
        Write-Host ""

        Write-Host "   Optional: any additional hostnames to map (e.g. api.test, dev.local)?"
        Write-Host "   Each shares the same port list. Avoid '.localhost' as a suffix --"
        Write-Host "   RFC 6761 reserves it for loopback and some libraries hardcode that."
        if (Read-CwcYesNo "   Add custom hostnames?" $false) {
            while ($true) {
                $fqdn = Read-Host "     Hostname (or Enter to finish)"
                if (-not $fqdn -or -not $fqdn.Trim()) { break }
                $fqdn = $fqdn.Trim()
                if (-not (Test-CwcFqdn $fqdn)) {
                    Write-Host "     Invalid hostname '$fqdn'. Use lowercase letters/digits/hyphens, dot-separated." -ForegroundColor Yellow
                    continue
                }
                $cfg.extra_hosts[$fqdn] = @{ target = 'host-gateway'; ports = $ports }
                Write-Host "     OK $fqdn -> host-gateway  ports=$($ports -join ',')" -ForegroundColor DarkGray
            }
        }

        Write-Host ""
        Write-Host "   To use a host service, tell the agent to reach it at" -ForegroundColor Cyan
        Write-Host "   http://host:<port> -- e.g. 'the dev server is at http://host:3000'." -ForegroundColor Cyan
    }
    Write-Host ""

    # Q4 -- explicit FQDN -> IP (advanced)
    Write-Host "4. Custom FQDN -> IP mappings" -ForegroundColor Green
    Write-Host "   Less common. Use this if you want to map a name to a specific IP"
    Write-Host "   that isn't your Docker host (e.g. legacy.box -> 10.5.1.20)."
    if (Read-CwcYesNo "   Add any custom mappings?") {
        while ($true) {
            $fqdn = Read-Host "     FQDN (or Enter to finish)"
            if (-not $fqdn -or -not $fqdn.Trim()) { break }
            $fqdn = $fqdn.Trim()
            if (-not (Test-CwcFqdn $fqdn)) {
                Write-Host "     Invalid FQDN '$fqdn'. Use lowercase letters/digits/hyphens, dot-separated." -ForegroundColor Yellow
                continue
            }
            $ip = Read-CwcNonEmpty "     IP for $fqdn"
            if (-not (Test-CwcHostTarget $ip)) {
                Write-Host "     '$ip' isn't a valid IP. Try again." -ForegroundColor Yellow
                continue
            }
            $cfg.extra_hosts[$fqdn] = @{ target = $ip; ports = @(443, 80) }
            # Auto-add containing /24 to allow_nets if it's RFC1918 and not already covered
            if ($ip -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$' -and
                $ip -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)') {
                $cidr = "$($Matches[1]).0/24"
                if ($cfg.allow_nets -notcontains $cidr) {
                    Write-Host "     (auto-allowing $cidr so $ip is reachable)" -ForegroundColor DarkGray
                    $cfg.allow_nets += $cidr
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
    if (Read-CwcYesNo "   Add any folder mounts?") {
        while ($true) {
            $name = Read-Host "     Name (e.g. obsidian, specs -- Enter to finish)"
            if (-not $name -or -not $name.Trim()) { break }
            $name = $name.Trim()
            if ($name -match '[^a-zA-Z0-9._-]') {
                Write-Host "     Name must be alphanumeric (with . _ - allowed)." -ForegroundColor Yellow
                continue
            }
            $path = Read-CwcNonEmpty "     Host path (e.g. C:\Users\you\Obsidian\Notes)"
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Host "     Path doesn't exist -- adding anyway, you can create it later." -ForegroundColor Yellow
            } else {
                $path = (Resolve-Path -LiteralPath $path).Path
            }
            $writable = Read-CwcYesNo "     Make it writable? (default: read-only)" $false
            $cfg.mounts[$name] = @{
                source   = $path
                target   = "C:\docs\$name"
                readonly = (-not $writable)
            }
            $modeLabel = if ($writable) { 'RW' } else { 'RO' }
            Write-Host "     OK $name [$modeLabel] $path -> C:\docs\$name" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # Q6 -- harden offer (per-project)
    Write-Host "6. Tamper-resistant hardening" -ForegroundColor Green
    Write-Host "   The default LAN lockdown is enforced inside the container -- code with"
    Write-Host "   admin rights in the container (which Claude has) can disable it via"
    Write-Host "   ``Remove-NetRoute``. 'Harden' adds an in-container watchdog that"
    Write-Host "   re-applies the routes every 2s, restores the hosts file from snapshot"
    Write-Host "   if changed, removes unauthorised routes, and logs new trust-store CAs."
    Write-Host ""
    Write-Host "   Trade-off: a bigger speed-bump, not real isolation. A determined agent"
    Write-Host "   can still defeat it. See docs/security.md."
    Write-Host ""
    Write-Host "   Recommended: ON. Toggle later with 'cwc harden enable/disable'."
    if (Read-CwcYesNo "   Enable hardening for this project?" $true) {
        $cfg.harden_enabled = $true
        Write-Host "     OK harden enabled" -ForegroundColor DarkGray
    } else {
        $cfg.harden_enabled = $false
        Write-Host "     x harden disabled" -ForegroundColor DarkGray
    }
    Write-Host ""

    # Summary
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host "  Summary" -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  LAN lockdown : enabled"
    Write-Host "  Harden       : $(if ($cfg.harden_enabled) { 'ENABLED' } else { 'disabled' })"
    Write-Host "  Allow CIDRs  : $(if ($cfg.allow_nets.Count) { $cfg.allow_nets -join ', ' } else { '(none)' })"
    if (@($cfg.extra_hosts.Keys).Count -gt 0) {
        Write-Host "  Host mappings:"
        foreach ($k in $cfg.extra_hosts.Keys) {
            $entry = $cfg.extra_hosts[$k]
            Write-Host "    $k -> $($entry.target)  ports=$($entry.ports -join ',')"
        }
    } else {
        Write-Host "  Host mappings: (none)"
    }
    if (@($cfg.mounts.Keys).Count -gt 0) {
        Write-Host "  Folder mounts:"
        foreach ($k in $cfg.mounts.Keys) {
            $m = $cfg.mounts[$k]
            $mode = if ($m.readonly) { 'RO' } else { 'RW' }
            Write-Host "    $k [$mode]  $($m.source) -> $($m.target)"
        }
    } else {
        Write-Host "  Folder mounts: (none)"
    }
    Write-Host ""

    if (Read-CwcYesNo "  Save this config?" $true) {
        Write-CwcProjectConfig $slug $cfg
        Write-Host "  OK saved to $(Get-CwcProjectConfigPath $slug)" -ForegroundColor Green
        Write-Host ""
        return $true
    } else {
        Write-Host "  Discarded. No changes written." -ForegroundColor DarkGray
        Write-Host ""
        return $false
    }
}

# 0ba. `cwc dev ...` -- session-scoped dev-mode launches + management subcommands.
# `cwc dev` (no other args) launches `claude` in the :dev image, building it locally
# from the Dockerfile next to cwc.ps1 if it doesn't exist yet. Falls through to the
# main launcher flow with $env:CWC_IMAGE rebound, so all the normal trust/setup/etc.
# paths still apply -- it's just a different image.
#
# `cwc dev <command>` runs <command> in the :dev container the same way. Host-side
# subcommands (setup/firewall/mount/trust/harden/auth/help) reject the wrapper --
# they don't need a container.
#
# Management subcommands (no container, just docker actions on the :dev tag):
#   cwc dev build       build :dev (compose build claude-code)
#   cwc dev rebuild     remove :dev then build --no-cache
#   cwc dev clean       remove :dev image
#   cwc dev status      show image presence + clone path + flag settings
#   cwc dev flag list                       show all flags + values
#   cwc dev flag set <name> <on|off>        set a persistent flag
#   cwc dev flag unset <name>               restore a flag to its default
if ($Cmd -and $Cmd.Count -gt 0 -and $Cmd[0] -eq 'dev') {
    $devSub = if ($Cmd.Count -ge 2) { $Cmd[1] } else { '' }

    # Management subcommands -- no container, no fall-through. Each requires a clone
    # because we have nothing useful to do without the Dockerfile (build/rebuild) or
    # because reporting "running from clone? yes/no" is part of the answer (status).
    if ($devSub -in @('build','rebuild','clean','status','flag')) {
        if (-not (Test-CwcInClone) -and $devSub -ne 'flag' -and $devSub -ne 'status' -and $devSub -ne 'clean') {
            Write-Host ""
            Write-Host "  cwc dev $devSub requires running from a git clone of the repo." -ForegroundColor Red
            Write-Host "  (No Dockerfile next to cwc.ps1.)"
            Write-Host ""
            exit 1
        }
        switch ($devSub) {
            'build' {
                Write-Host "[cwc dev] building $cwcDevImage..." -ForegroundColor Cyan
                $env:CWC_IMAGE = $cwcDevImage
                & docker compose -f (Join-Path $scriptRoot 'docker-compose.yml') build claude-code
                if ($LASTEXITCODE -ne 0) { Write-Host "[cwc dev] build failed" -ForegroundColor Red; exit 1 }
                Write-Host "[cwc dev] built $cwcDevImage" -ForegroundColor Green
            }
            'rebuild' {
                Write-Host "[cwc dev] removing $cwcDevImage and rebuilding from scratch..." -ForegroundColor Cyan
                docker image rm $cwcDevImage *> $null   # tolerate "not found"
                $env:CWC_IMAGE = $cwcDevImage
                & docker compose -f (Join-Path $scriptRoot 'docker-compose.yml') build --no-cache claude-code
                if ($LASTEXITCODE -ne 0) { Write-Host "[cwc dev] rebuild failed" -ForegroundColor Red; exit 1 }
                Write-Host "[cwc dev] rebuilt $cwcDevImage (no cache)" -ForegroundColor Green
            }
            'clean' {
                docker image inspect $cwcDevImage *> $null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[cwc dev] $cwcDevImage not found locally -- nothing to clean." -ForegroundColor DarkGray
                    exit 0
                }
                docker image rm $cwcDevImage
                if ($LASTEXITCODE -ne 0) { Write-Host "[cwc dev] image rm failed" -ForegroundColor Red; exit 1 }
                Write-Host "[cwc dev] removed $cwcDevImage" -ForegroundColor Yellow
            }
            'status' {
                docker image inspect $cwcDevImage *> $null
                $imgPresent = ($LASTEXITCODE -eq 0)
                $inClone    = Test-CwcInClone
                $flags      = Read-CwcDevConfig
                Write-Host ""
                Write-Host "  cwc dev status" -ForegroundColor Cyan
                Write-Host "    image      : $cwcDevImage"
                Write-Host "    image local: $(if ($imgPresent) { 'present' } else { 'MISSING (run cwc dev build)' })" -ForegroundColor $(if ($imgPresent) { 'Green' } else { 'Yellow' })
                Write-Host "    clone      : $(if ($inClone) { $scriptRoot } else { 'NOT a clone (run from a clone of the repo)' })" -ForegroundColor $(if ($inClone) { 'Green' } else { 'Yellow' })
                Write-Host "    config     : $cwcDevConfigPath"
                Write-Host ""
                Write-Host "  Flags" -ForegroundColor Cyan
                foreach ($k in ($flags.Keys | Sort-Object)) {
                    $val = if ($flags[$k]) { 'on' } else { 'off' }
                    $isDefault = ($flags[$k] -eq $script:cwcDevFlagDefaults[$k])
                    $tag = if ($isDefault) { '(default)' } else { '(custom)' }
                    Write-Host "    $k = $val  $tag"
                }
                Write-Host ""
            }
            'flag' {
                $flagSub  = if ($Cmd.Count -ge 3) { $Cmd[2] } else { 'list' }
                $flagName = if ($Cmd.Count -ge 4) { $Cmd[3] } else { $null }
                $flagVal  = if ($Cmd.Count -ge 5) { $Cmd[4] } else { $null }
                $flags = Read-CwcDevConfig
                switch ($flagSub) {
                    'list' {
                        Write-Host ""
                        Write-Host "  Dev flags (set with 'cwc dev flag set <name> <on|off>'):" -ForegroundColor Cyan
                        foreach ($k in ($flags.Keys | Sort-Object)) {
                            $val = if ($flags[$k]) { 'on' } else { 'off' }
                            $def = if ($script:cwcDevFlagDefaults[$k]) { 'on' } else { 'off' }
                            Write-Host "    $k = $val  (default: $def)"
                        }
                        Write-Host ""
                    }
                    'set' {
                        if (-not $flagName -or -not $flagVal) {
                            Write-Host "Usage: cwc dev flag set <name> <on|off>" -ForegroundColor Red
                            exit 1
                        }
                        if (-not $script:cwcDevFlagDefaults.ContainsKey($flagName)) {
                            Write-Host "Unknown flag: '$flagName'. Run 'cwc dev flag list' to see available flags." -ForegroundColor Red
                            exit 1
                        }
                        $bool = switch -Regex ($flagVal.ToString().ToLower()) {
                            '^(on|true|1|yes|y)$'  { $true; break }
                            '^(off|false|0|no|n)$' { $false; break }
                            default { Write-Host "Value must be on|off (got '$flagVal')." -ForegroundColor Red; exit 1 }
                        }
                        $flags[$flagName] = $bool
                        Write-CwcDevConfig $flags
                        Write-Host "Set $flagName = $(if ($bool) { 'on' } else { 'off' })" -ForegroundColor Green
                    }
                    'unset' {
                        if (-not $flagName) { Write-Host "Usage: cwc dev flag unset <name>" -ForegroundColor Red; exit 1 }
                        if (-not $script:cwcDevFlagDefaults.ContainsKey($flagName)) {
                            Write-Host "Unknown flag: '$flagName'." -ForegroundColor Red
                            exit 1
                        }
                        $flags[$flagName] = [bool]$script:cwcDevFlagDefaults[$flagName]
                        Write-CwcDevConfig $flags
                        Write-Host "Reset $flagName to default ($(if ($flags[$flagName]) { 'on' } else { 'off' }))" -ForegroundColor Yellow
                    }
                    default {
                        Write-Host "Usage: cwc dev flag {list|set <name> <on|off>|unset <name>}" -ForegroundColor Red
                        exit 1
                    }
                }
            }
        }
        exit 0
    }

    # Wrapping host-side subcommands in `cwc dev` is meaningless -- they never start
    # a container. Refuse with a hint instead of silently doing the wrong thing.
    $hostSubs = @('setup','firewall','mount','trust','untrust','harden','auth','help','-Help','-h')
    if ($devSub -in $hostSubs) {
        Write-Host ""
        Write-Host "  '$devSub' is host-side -- run 'cwc $devSub ...' (no 'dev' wrapper needed)." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    # Session start. Require a clone (we need the Dockerfile to build :dev), set the
    # image env, ensure :dev exists locally (build inline if missing), apply persistent
    # flags, and FALL THROUGH to the main launcher flow with 'dev' stripped from $Cmd.
    if (-not (Test-CwcInClone)) {
        Write-Host ""
        Write-Host "  cwc dev requires running from a git clone of the repo." -ForegroundColor Red
        Write-Host "  (No Dockerfile next to cwc.ps1 at $scriptRoot.)"
        Write-Host "  Clone https://github.com/vinylflamingo/claude-win-container, then point your alias at the clone."
        Write-Host ""
        exit 1
    }

    $script:cwcDevMode = $true
    $env:CWC_IMAGE     = $cwcDevImage

    docker image inspect $cwcDevImage *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[cwc dev] $cwcDevImage missing -- building from local Dockerfile..." -ForegroundColor Cyan
        Write-Host "[cwc dev] (first build is ~5-10 min; subsequent builds are layer-cached)" -ForegroundColor DarkGray
        & docker compose -f (Join-Path $scriptRoot 'docker-compose.yml') build claude-code
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[cwc dev] build failed" -ForegroundColor Red
            exit 1
        }
    }

    $devFlags = Read-CwcDevConfig
    if ($devFlags.live_entrypoint_mount) {
        $entrypointSrc = Join-Path $scriptRoot 'entrypoint.ps1'
        if (Test-Path -LiteralPath $entrypointSrc) {
            $script:cwcDevExtraMounts += @('--volume', "${entrypointSrc}:C:\entrypoint.ps1:ro")
            Write-Host "[cwc dev] live entrypoint mount: $entrypointSrc -> C:\entrypoint.ps1 (ro)" -ForegroundColor Magenta
        } else {
            Write-Host "[cwc dev] live_entrypoint_mount on, but $entrypointSrc not found -- skipping mount." -ForegroundColor Yellow
        }
    }

    Write-Host "[cwc dev] running with $cwcDevImage" -ForegroundColor Magenta

    # Strip 'dev' from $Cmd so the main flow sees the underlying command (or empty
    # for "just launch claude").
    $Cmd = if ($Cmd.Count -ge 2) { $Cmd[1..($Cmd.Count - 1)] } else { @() }
    # Fall through.
}

# 0bb. `cwc setup` -- per-project setup wizard.
# Walks the user through 6 questions and writes ~/.cwc/projects/<slug>/config.json.
# This is the ONLY way to create that file; main launcher flow auto-triggers this
# (interactively) on first `cwc` in an unconfigured project, but the user can also
# run it explicitly to reconfigure.
if ($Cmd -and $Cmd.Count -gt 0 -and $Cmd[0] -eq 'setup') {
    if (-not (Test-CwcInProjectRoot)) {
        Write-Host ""
        Write-Host "  '$projectDir' doesn't look like a project root." -ForegroundColor Yellow
        Write-Host "  cwc setup configures one project at a time -- cd to a project first."
        Write-Host ""
        exit 1
    }
    if (-not (Test-CwcInteractive)) {
        Write-Host ""
        Write-Host "  cwc setup requires an interactive session (it asks questions)." -ForegroundColor Red
        Write-Host "  Re-run from a real terminal."
        Write-Host ""
        exit 1
    }
    $slugForSetup = Get-ProjectSlug $projectDir
    $saved = Invoke-CwcProjectSetup -ProjectDir $projectDir -Slug $slugForSetup
    if ($saved) {
        Write-Host "  Setup complete. Run 'cwc' from this directory to launch." -ForegroundColor Green
        Write-Host ""
    }
    exit 0
}

# 0c. `cwc firewall ...` subcommand
# Two scopes:
#   denylist {list|add|remove|reset}  -- GLOBAL (security policy applied to every project).
#   everything else                   -- PER-PROJECT (operates on the current directory's
#                                        config; requires a project root and 'cwc setup' first).
if ($Cmd -and $Cmd.Count -gt 0 -and $Cmd[0] -eq 'firewall') {
    $sub = if ($Cmd.Count -ge 2) { $Cmd[1] } else { 'list' }
    $arg = if ($Cmd.Count -ge 3) { $Cmd[2] } else { $null }

    # Denylist is global (cross-project security policy). Handle it before the
    # project-root check so it's usable from anywhere.
    if ($sub -eq 'denylist') {
        $sub2 = if ($Cmd.Count -ge 3) { $Cmd[2] } else { 'list' }
        $denyArg = if ($Cmd.Count -ge 4) { $Cmd[3] } else { $null }
        $globalCfg = Read-CwcGlobalConfig
        $denylist = @($globalCfg.host_denylist)
        switch ($sub2) {
            'list' {
                Write-Host ""
                if ($denylist.Count -gt 0) {
                    Write-Host "  Host denylist (cwc firewall host-add refuses these):" -ForegroundColor Cyan
                    $defaults = Get-CwcDefaultDenylist
                    foreach ($p in ($denylist | Sort-Object)) {
                        $tag = if ($defaults -contains $p) { '(default)' } else { '(custom)' }
                        Write-Host "    $p  $tag"
                    }
                } else {
                    Write-Host "  (denylist empty -- no FQDNs are refused)" -ForegroundColor Yellow
                }
                Write-Host ""
            }
            'add' {
                if (-not $denyArg) { Write-Host "Usage: cwc firewall denylist add <fqdn-or-pattern>" -ForegroundColor Red; exit 1 }
                $pattern = $denyArg.ToLowerInvariant()
                if ($denylist -notcontains $pattern) {
                    $globalCfg.host_denylist = @($denylist) + $pattern
                    Write-CwcGlobalConfig $globalCfg
                    Write-Host "Denylisted: $pattern" -ForegroundColor Green
                } else {
                    Write-Host "$pattern already denylisted." -ForegroundColor DarkGray
                }
            }
            'remove' {
                if (-not $denyArg) { Write-Host "Usage: cwc firewall denylist remove <pattern>" -ForegroundColor Red; exit 1 }
                $pattern = $denyArg.ToLowerInvariant()
                $defaults = Get-CwcDefaultDenylist
                if ($defaults -contains $pattern) {
                    Write-Host ""
                    Write-Host "  WARNING: '$pattern' is a default denylist entry." -ForegroundColor Yellow
                    Write-Host "  Removing it could allow agents to redirect Anthropic auth traffic via" -ForegroundColor Yellow
                    Write-Host "  hosts-file injection -- exfiltrating your API key on the next session." -ForegroundColor Yellow
                    Write-Host ""
                    $resp = Read-Host "  Remove anyway? [y/N]"
                    if ($resp -notmatch '^(y|yes)$') {
                        Write-Host "  Cancelled." -ForegroundColor DarkGray
                        exit 0
                    }
                }
                $newList = @($denylist | Where-Object { $_ -ne $pattern })
                if ($newList.Count -lt $denylist.Count) {
                    $globalCfg.host_denylist = $newList
                    Write-CwcGlobalConfig $globalCfg
                    Write-Host "Removed: $pattern" -ForegroundColor Yellow
                } else {
                    Write-Host "$pattern not in denylist." -ForegroundColor DarkGray
                }
            }
            'reset' {
                $globalCfg.host_denylist = @(Get-CwcDefaultDenylist)
                Write-CwcGlobalConfig $globalCfg
                Write-Host "Denylist reset to defaults." -ForegroundColor Green
            }
            default {
                Write-Host "Unknown denylist subcommand: $sub2" -ForegroundColor Red
                Write-Host "Usage: cwc firewall denylist {list|add <pattern>|remove <pattern>|reset}"
                exit 1
            }
        }
        exit 0
    }

    # Everything else is per-project. Require a project root + an existing project config.
    if (-not (Test-CwcInProjectRoot)) {
        Write-Host ""
        Write-Host "  '$projectDir' doesn't look like a project root." -ForegroundColor Yellow
        Write-Host "  cwc firewall operates per-project -- cd to a project directory first."
        Write-Host ""
        exit 1
    }
    $slugForFirewall = Get-ProjectSlug $projectDir
    $cfg = Get-RequiredCwcProjectConfig $slugForFirewall $projectDir
    # Denylist is consulted for host-add validation; pull from global.
    $globalDenylist = (Read-CwcGlobalConfig).host_denylist

    switch ($sub) {
        'list' {
            $state = if ($cfg.lockdown_lan) { 'enabled' } else { 'disabled' }
            Write-Host ""
            Write-Host "  Project      : $projectDir" -ForegroundColor Cyan
            Write-Host "  LAN lockdown : $state"
            Write-Host "  Allow-list   : $(if ($cfg.allow_nets.Count) { $cfg.allow_nets -join ', ' } else { '(none)' })"
            if (@($cfg.extra_hosts.Keys).Count -gt 0) {
                Write-Host "  Host mappings:"
                foreach ($fqdn in ($cfg.extra_hosts.Keys | Sort-Object)) {
                    $entry = $cfg.extra_hosts[$fqdn]
                    Write-Host "    $fqdn -> $($entry.target)  ports=$($entry.ports -join ',')"
                }
            } else {
                Write-Host "  Host mappings: (none)"
            }
            $hardenStateLabel = if ($cfg.harden_enabled) { 'enabled' } else { 'disabled' }
            Write-Host "  Harden       : $hardenStateLabel"
            Write-Host "  Config file  : $(Get-CwcProjectConfigPath $slugForFirewall)"
            Write-Host ""
            Write-Host "  Shell env CWC_* (one-shot) overrides this config; project .env does not." -ForegroundColor DarkGray
            Write-Host ""
        }
        'allow' {
            if (-not $arg) { Write-Host "Usage: cwc firewall allow <cidr>" -ForegroundColor Red; exit 1 }
            if ($cfg.allow_nets -notcontains $arg) {
                $cfg.allow_nets = @($cfg.allow_nets) + $arg
                Write-CwcProjectConfig $slugForFirewall $cfg
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
                Write-CwcProjectConfig $slugForFirewall $cfg
                Write-Host "Removed: $arg" -ForegroundColor Yellow
            } else {
                Write-Host "$arg was not in allow-list." -ForegroundColor DarkGray
            }
        }
        'enable' {
            $cfg.lockdown_lan = $true
            Write-CwcProjectConfig $slugForFirewall $cfg
            Write-Host "LAN lockdown enabled for this project." -ForegroundColor Green
        }
        'disable' {
            $cfg.lockdown_lan = $false
            Write-CwcProjectConfig $slugForFirewall $cfg
            Write-Host "LAN lockdown disabled for this project." -ForegroundColor Yellow
        }
        'host-list' {
            Write-Host ""
            if (@($cfg.extra_hosts.Keys).Count -gt 0) {
                Write-Host "  Host mappings:" -ForegroundColor Cyan
                foreach ($fqdn in ($cfg.extra_hosts.Keys | Sort-Object)) {
                    $entry = $cfg.extra_hosts[$fqdn]
                    Write-Host "    $fqdn -> $($entry.target)  ports=$($entry.ports -join ',')"
                }
            } else {
                Write-Host "  (no host mappings)" -ForegroundColor DarkGray
            }
            Write-Host ""
        }
        'host-add' {
            if (-not $arg) {
                Write-Host "Usage: cwc firewall host-add <fqdn> [target] [ports]" -ForegroundColor Red
                Write-Host "  Default target  : 'host-gateway' (the Docker host's vNIC)"
                Write-Host "  Default ports   : '443,80' (comma-separated TCP ports)"
                Write-Host ""
                Write-Host "  Examples:"
                Write-Host "    cwc firewall host-add api.local                      # host-gateway, 443+80"
                Write-Host "    cwc firewall host-add api.local host-gateway 443     # 443 only"
                Write-Host "    cwc firewall host-add db.local 192.168.1.5 5432      # explicit IP, port 5432"
                exit 1
            }
            $target = if ($Cmd.Count -ge 4) { $Cmd[3] } else { 'host-gateway' }
            $portsArg = if ($Cmd.Count -ge 5) { $Cmd[4] } else { '443,80' }

            if (-not (Test-CwcFqdn $arg)) {
                Write-Host "Invalid FQDN: '$arg'" -ForegroundColor Red
                Write-Host "  FQDNs must be lowercase letters/digits/hyphens, dot-separated, max 253 chars."
                exit 1
            }
            if (-not (Test-CwcHostTarget $target)) {
                Write-Host "Invalid target: '$target'" -ForegroundColor Red
                Write-Host "  Target must be 'host-gateway' or a valid IPv4/IPv6 address."
                exit 1
            }
            if (Test-CwcFqdnDenied -fqdn $arg -denylist @($globalDenylist)) {
                Write-Host "Refused: '$arg' matches the host-add denylist." -ForegroundColor Red
                Write-Host "  Mapping this FQDN could redirect Anthropic auth traffic via hosts-file injection."
                Write-Host "  Run 'cwc firewall denylist list' to see active rules."
                Write-Host "  If you really need this, use 'cwc firewall denylist remove <pattern>' first (not recommended)."
                exit 1
            }

            # Parse + validate ports.
            $ports = @()
            foreach ($pStr in $portsArg.Split(',')) {
                $pStr = $pStr.Trim()
                if (-not $pStr) { continue }
                $parsed = 0
                if (-not [int]::TryParse($pStr, [ref]$parsed)) {
                    Write-Host "Invalid port: '$pStr' (not a number)" -ForegroundColor Red
                    exit 1
                }
                if ($parsed -lt 1 -or $parsed -gt 65535) {
                    Write-Host "Port out of range: $parsed (must be 1-65535)" -ForegroundColor Red
                    exit 1
                }
                $ports += $parsed
            }
            if ($ports.Count -eq 0) {
                Write-Host "At least one port required." -ForegroundColor Red
                exit 1
            }
            $ports = @($ports | Select-Object -Unique)

            $cfg.extra_hosts[$arg] = @{ target = $target; ports = $ports }
            Write-CwcProjectConfig $slugForFirewall $cfg
            Write-Host "Mapped: $arg -> $target  ports=$($ports -join ',')" -ForegroundColor Green
            if ($target -ne 'host-gateway') {
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
                Write-CwcProjectConfig $slugForFirewall $cfg
                Write-Host "Removed: $arg" -ForegroundColor Yellow
            } else {
                Write-Host "$arg was not mapped." -ForegroundColor DarkGray
            }
        }
        default {
            Write-Host "Unknown firewall subcommand: $sub" -ForegroundColor Red
            Write-Host "Usage: cwc firewall {list|allow <cidr>|deny <cidr>|enable|disable|"
            Write-Host "                     host-list|host-add <fqdn> [ip]|host-remove <fqdn>|"
            Write-Host "                     denylist {list|add|remove|reset}}"
            exit 1
        }
    }
    exit 0
}

# `cwc mount ...` subcommand -- per-project. Manages additional bind-mounts (e.g. an
# Obsidian vault, design-spec folder, runbooks) for THIS project. Source paths are
# mounted into the container at C:\docs\<name> by default; readonly is the default.
# Different projects can mount different things without leaking into each other.
if ($Cmd -and $Cmd.Count -gt 0 -and $Cmd[0] -eq 'mount') {
    $sub = if ($Cmd.Count -ge 2) { $Cmd[1] } else { 'list' }
    if (-not (Test-CwcInProjectRoot)) {
        Write-Host ""
        Write-Host "  '$projectDir' doesn't look like a project root." -ForegroundColor Yellow
        Write-Host "  cwc mount operates per-project -- cd to a project directory first."
        Write-Host ""
        exit 1
    }
    $slugForMount = Get-ProjectSlug $projectDir
    $cfg = Get-RequiredCwcProjectConfig $slugForMount $projectDir
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
            Write-CwcProjectConfig $slugForMount $cfg
            $modeLabel = if ($mode -eq 'ro') { 'readonly' } else { 'writable' }
            Write-Host "Added: $name  [$modeLabel]  $source -> C:\docs\$name" -ForegroundColor Green
        }
        'remove' {
            $name = if ($Cmd.Count -ge 3) { $Cmd[2] } else { $null }
            if (-not $name) { Write-Host "Usage: cwc mount remove <name>" -ForegroundColor Red; exit 1 }
            if ($cfg.mounts.ContainsKey($name)) {
                $cfg.mounts.Remove($name)
                Write-CwcProjectConfig $slugForMount $cfg
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

# `cwc trust` / `cwc untrust` -- manage per-project file-trust hashes.
# Trust covers files that drive next-session policy: claude-sandbox.overlay.yml,
# .env, .mcp.json. The agent has RW on the workspace, so any of these can be edited
# from inside the container; trust forces the dev to ack changes before they take effect.
if ($Cmd -and $Cmd.Count -gt 0 -and ($Cmd[0] -eq 'trust' -or $Cmd[0] -eq 'untrust')) {
    if (-not $Force) {
        if (-not (Test-CwcInProjectRoot)) {
            Write-Host ""
            Write-Host "  '$projectDir' doesn't look like a project root." -ForegroundColor Yellow
            Write-Host "  cwc trust operates per-project -- cd to a project directory first."
            Write-Host ""
            exit 1
        }
    }
    $slugForTrust = Get-ProjectSlug $projectDir
    # Trust intentionally tolerates a missing project config: it's used in the main
    # launcher flow before a config might exist (older cwc setup hasn't been run yet).
    # Read returns $null -> Get-CwcProjectTrustState reports everything as untrusted.
    $cfgForTrust  = Read-CwcProjectConfig $slugForTrust

    if ($Cmd[0] -eq 'untrust') {
        if ($cfgForTrust -and $cfgForTrust.trusted_files -and $cfgForTrust.trusted_files.Count -gt 0) {
            $cfgForTrust.trusted_files = @{}
            Write-CwcProjectConfig $slugForTrust $cfgForTrust
            Write-Host "Removed trust for project: $projectDir" -ForegroundColor Yellow
            Write-Host "  Next 'cwc' run will re-prompt for trust."
        } else {
            Write-Host "No trust state recorded for: $projectDir" -ForegroundColor DarkGray
        }
        exit 0
    }

    # cwc trust [list]
    $trustSub = if ($Cmd.Count -ge 2) { $Cmd[1] } else { '' }
    $state = Get-CwcProjectTrustState $cfgForTrust $projectDir
    if ($trustSub -eq 'list') {
        Write-Host ""
        Write-Host "  Project: $projectDir" -ForegroundColor Cyan
        Write-Host "  Slug:    $slugForTrust" -ForegroundColor DarkGray
        Show-TrustState $state
        Write-Host ""
        exit 0
    }
    if (-not $state.any_present) {
        Write-Host "  No tracked files in this project -- nothing to trust." -ForegroundColor DarkGray
        Write-Host "  Tracked: $($script:cwcTrustedFileNames -join ', ')"
        exit 0
    }
    Write-Host ""
    Write-Host "  Trusting current state of:" -ForegroundColor Cyan
    Show-TrustState $state
    Save-CwcProjectTrust $slugForTrust $projectDir | Out-Null
    Write-Host ""
    Write-Host "  Trusted current state for: $projectDir" -ForegroundColor Green
    exit 0
}

# `cwc harden ...` -- opt-in tamper-resistant in-container hardening.
# When enabled, the container runs a watchdog that re-applies blackhole routes,
# restores the hosts file from snapshot if changed, removes unauthorized /32 allow-routes
# to RFC1918 destinations, and logs new entries in the trust store. The agent in the
# container has admin rights and can still defeat this with sufficient effort, but the
# bar moves from "Remove-NetRoute" to "find and stop the watchdog AND restore routes
# AND keep doing so faster than the next watchdog respawn."
#
# This does NOT add host-side enforcement. See docs/security.md for the threat model
# and the limitations.
if ($Cmd -and $Cmd.Count -gt 0 -and $Cmd[0] -eq 'harden') {
    $hardenSub = if ($Cmd.Count -ge 2) { $Cmd[1] } else { 'status' }
    if (-not (Test-CwcInProjectRoot)) {
        Write-Host ""
        Write-Host "  '$projectDir' doesn't look like a project root." -ForegroundColor Yellow
        Write-Host "  cwc harden operates per-project -- cd to a project directory first."
        Write-Host ""
        exit 1
    }
    $slugForHarden = Get-ProjectSlug $projectDir
    $cfgForHarden  = Get-RequiredCwcProjectConfig $slugForHarden $projectDir
    switch ($hardenSub) {
        'enable' {
            if ($cfgForHarden.harden_enabled) {
                Write-Host "Harden already enabled for this project." -ForegroundColor DarkGray
                exit 0
            }
            $cfgForHarden.harden_enabled = $true
            Write-CwcProjectConfig $slugForHarden $cfgForHarden
            Write-Host ""
            Write-Host "Harden enabled for this project." -ForegroundColor Green
            Write-Host "  Next 'cwc' session in $projectDir will run with the in-container watchdog active."
            Write-Host "  See 'cwc harden status' for what gets enforced."
            Write-Host ""
        }
        'disable' {
            if (-not $cfgForHarden.harden_enabled) {
                Write-Host "Harden already disabled for this project." -ForegroundColor DarkGray
                exit 0
            }
            $cfgForHarden.harden_enabled = $false
            Write-CwcProjectConfig $slugForHarden $cfgForHarden
            Write-Host "Harden disabled for this project. Next 'cwc' session will run without the watchdog." -ForegroundColor Yellow
        }
        'status' {
            $state = if ($cfgForHarden.harden_enabled) { 'ENABLED' } else { 'disabled' }
            $color = if ($cfgForHarden.harden_enabled) { 'Green' } else { 'DarkGray' }
            Write-Host ""
            Write-Host "  Harden : $state" -ForegroundColor $color
            Write-Host ""
            if ($cfgForHarden.harden_enabled) {
                Write-Host "  When a session starts, the entrypoint:"
                Write-Host "    - applies the LAN-egress blackhole routes (always)"
                Write-Host "    - spawns a watchdog process running every 2s"
                Write-Host ""
                Write-Host "  The watchdog:"
                Write-Host "    - re-applies blackhole routes if any are removed"
                Write-Host "    - removes unauthorized /32 allow-routes to RFC1918 destinations"
                Write-Host "    - restores the hosts file from snapshot if its contents change"
                Write-Host "    - logs new entries in the trust store (does not auto-revert)"
                Write-Host ""
                Write-Host "  Limitations:"
                Write-Host "    - The agent has admin in the container; with effort it can still"
                Write-Host "      defeat the watchdog. This is a 'speed-bump made bigger,' not isolation."
                Write-Host "    - Host-side enforcement (real isolation) is documented as future work in"
                Write-Host "      docs/security.md -- not implemented in v1 because Docker Desktop's"
                Write-Host "      Windows containers don't expose a clean host-side firewall hook."
            } else {
                Write-Host "  Run 'cwc harden enable' to turn on the in-container watchdog."
            }
            Write-Host ""
        }
        default {
            Write-Host "Usage: cwc harden {enable|disable|status}" -ForegroundColor Red
            exit 1
        }
    }
    exit 0
}

# `cwc auth ...` -- manage shared auth state at ~/.claude-win-container/auth/.
# Currently supports: reset (wipe shared auth -- re-auth on next run), where (print path).
if ($Cmd -and $Cmd.Count -gt 0 -and $Cmd[0] -eq 'auth') {
    $authSub = if ($Cmd.Count -ge 2) { $Cmd[1] } else { 'help' }
    $authDirForCmd = Join-Path $env:USERPROFILE '.claude-win-container\auth'
    switch ($authSub) {
        'reset' {
            if (-not (Test-Path $authDirForCmd)) {
                Write-Host "  Auth dir not present at $authDirForCmd -- nothing to reset." -ForegroundColor DarkGray
                exit 0
            }
            Write-Host ""
            Write-Host "  This will remove all shared auth state at:" -ForegroundColor Yellow
            Write-Host "    $authDirForCmd"
            Write-Host ""
            Write-Host "  You'll need to re-authenticate (OAuth flow / API key) on the next 'cwc' run."
            Write-Host "  Per-project state (sessions, memory, plugins) is unaffected."
            Write-Host ""
            $resp = Read-Host "  Reset shared auth? [y/N]"
            if ($resp -notmatch '^(y|yes)$') { Write-Host "  Cancelled." -ForegroundColor DarkGray; exit 0 }
            Remove-Item -Recurse -Force -LiteralPath $authDirForCmd -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $authDirForCmd | Out-Null
            Write-Host "  Auth dir wiped. Next cwc run starts from clean." -ForegroundColor Green
        }
        'where' {
            Write-Host ""
            Write-Host "  Shared auth dir : $authDirForCmd" -ForegroundColor Cyan
            Write-Host "  Per-project root: $(Join-Path $env:USERPROFILE '.claude-win-container\projects')"
            Write-Host ""
        }
        default {
            Write-Host "Usage: cwc auth {reset|where}" -ForegroundColor Red
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
    if (-not (Test-CwcInProjectRoot)) {
        Write-Host ""
        Write-Host "  '$projectDir' doesn't look like a project root." -ForegroundColor Yellow
        Write-Host "  (no .git, package.json, .sln, .mcp.json, pyproject.toml, go.mod, Cargo.toml)"
        Write-Host "  Use -Force if you really want to launch here."
        Write-Host ""
        exit 1
    }
}

# 2. Resolve per-project state directory (Get-ProjectSlug is defined in the helpers
# section above so the trust subcommand can reuse it).
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

# 2b. Per-project config + trust check.
# First load the per-project config. If it doesn't exist, auto-trigger the setup
# wizard inline (interactive sessions only) -- non-interactive sessions fail closed
# with an actionable error.
$cwcCfg = Read-CwcProjectConfig $slug
if (-not $cwcCfg) {
    if (-not (Test-CwcInteractive)) {
        Write-Host ""
        Write-Host "  No cwc config for this project, and this isn't an interactive session." -ForegroundColor Red
        Write-Host "  Run 'cwc setup' from $projectDir from a real terminal first." -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }
    Write-Host ""
    Write-Host "  First time using cwc in this project. Let's configure its sandbox." -ForegroundColor Cyan
    Write-Host "  (You can re-run 'cwc setup' anytime to reconfigure.)" -ForegroundColor DarkGray
    Write-Host ""
    $saved = Invoke-CwcProjectSetup -ProjectDir $projectDir -Slug $slug
    if (-not $saved) {
        Write-Host "  Setup not saved -- aborting launch." -ForegroundColor Yellow
        Write-Host "  Re-run 'cwc' (or 'cwc setup') when you're ready to configure."
        exit 1
    }
    $cwcCfg = Read-CwcProjectConfig $slug
}

# Trust covers workspace files that drive next-session policy (claude-sandbox.overlay.yml,
# .env, .mcp.json). The agent has RW in the workspace, so any of these can be agent-edited;
# we refuse to silently inherit those edits.
$trustState = Get-CwcProjectTrustState $cwcCfg $projectDir
if ($trustState.any_changed) {
    Write-Host ""
    Write-Host "  Trust check: workspace policy files have changed" -ForegroundColor Yellow
    Show-TrustState $trustState
    Write-Host ""
    Write-Host "  These files drive what flows into the container:" -ForegroundColor DarkGray
    Write-Host "    claude-sandbox.overlay.yml  -- auto-loaded compose overlay (mounts, networks, etc.)"
    Write-Host "    .env                        -- env vars forwarded into the container"
    Write-Host "    .mcp.json                   -- MCP servers + extra env-key references that get forwarded"
    Write-Host ""
    if (-not (Test-CwcInteractive)) {
        Write-Host "  Refusing to launch (non-interactive session)." -ForegroundColor Red
        Write-Host "  Run 'cwc trust' from this project to acknowledge."
        Write-Host ""
        exit 1
    }
    $resp = Read-Host "  Trust current state and continue? [y/N]"
    if ($resp -notmatch '^(y|yes)$') {
        Write-Host "  Cancelled." -ForegroundColor DarkGray
        exit 1
    }
    Save-CwcProjectTrust $slug $projectDir | Out-Null
    Write-Host "  Saved trust for this project." -ForegroundColor Green
    Write-Host ""
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

# 4a. Apply per-project config (~/.cwc/projects/<slug>/config.json) to the firewall env vars.
# Config was already read above for the trust check; reuse it. Per-project config is
# the only source for CWC_* values now -- project .env can no longer drive them
# (Phase 2 of the security plan; see docs/security.md).
if (-not $env:CWC_LOCKDOWN_LAN) {
    $env:CWC_LOCKDOWN_LAN = if ($cwcCfg.lockdown_lan) { '1' } else { '0' }
}
if (@($cwcCfg.allow_nets).Count -gt 0) {
    $existing = if ($env:CWC_ALLOW_NETS) { $env:CWC_ALLOW_NETS.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { @() }
    $merged = @($existing + $cwcCfg.allow_nets) | Select-Object -Unique
    $env:CWC_ALLOW_NETS = $merged -join ','
}

# Pass extra_hosts to the entrypoint via CWC_EXTRA_HOSTS env var. The entrypoint sets
# up netsh portproxy for each fqdn:target:port and writes hosts file entries pointing
# the FQDN at a per-FQDN loopback IP.
#
# Format: "fqdn|target|port1,port2;fqdn2|target2|port3"
# Uses pipe + semicolon (not colon + comma) to keep ports unambiguous and avoid
# colliding with IPv6 colons in target. Old colon-only format from pre-Phase 4 is
# still accepted by the entrypoint as a fallback (no ports -> defaults to 443,80).
$hostSummary = @()
if (@($cwcCfg.extra_hosts.Keys).Count -gt 0) {
    $pairs = foreach ($fqdn in $cwcCfg.extra_hosts.Keys) {
        $entry = $cwcCfg.extra_hosts[$fqdn]
        $target = $entry.target
        $portsStr = ($entry.ports -join ',')
        $hostSummary += "$fqdn -> $target ($portsStr)"
        "${fqdn}|${target}|${portsStr}"
    }
    $env:CWC_EXTRA_HOSTS = $pairs -join ';'
}

# Build --volume flags for additional bind mounts (Obsidian vault, design specs, etc.).
# Skips mounts whose source has gone missing -- warns but doesn't fail the session.
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

# Append dev-mode extra mounts (e.g. live_entrypoint_mount). $script:cwcDevExtraMounts
# is populated by the `cwc dev` subcommand block when a flag asks for an extra bind.
# Empty in non-dev sessions -- this is a no-op then.
if ($script:cwcDevExtraMounts -and $script:cwcDevExtraMounts.Count -gt 0) {
    $mountFlags += $script:cwcDevExtraMounts
}

# 4b. Forward env vars from project's .env
# Allowlist:
#   - ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN  (auth -- used by Claude itself)
#   - any key prefixed CLAUDE_*                   (consumer-defined Claude config)
#   - any key referenced as ${KEY} in .mcp.json   (MCP server runtime config)
# We do NOT forward arbitrary keys -- the project's .env may contain DB passwords, etc.
#
# CWC_* keys are NEVER read from project .env -- they're sandbox-control flags and the
# agent has RW on the workspace, so allowing project .env to set them would let the
# agent silently disable the lockdown / inject into the hosts file on the next launch.
# Shell env CWC_* still works (one-shot dev override); per-project config
# (~/.cwc/projects/<slug>/config.json) is the persistent source. (Phase 2 of the
# security plan; see docs/security.md.)
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
[void]$forwardKeys.Add('CWC_HARDEN')

# Surface harden_enabled into $env:CWC_HARDEN so the entrypoint sees it the same way
# it sees any other CWC_* sandbox flag.
if (-not $env:CWC_HARDEN) {
    $env:CWC_HARDEN = if ($cwcCfg.harden_enabled) { '1' } else { '0' }
}
foreach ($k in $dotenv.Keys) {
    # CWC_* deliberately excluded here -- see comment block above.
    if ($k -like 'CLAUDE_*' -or $k -like 'ANTHROPIC_*') {
        [void]$forwardKeys.Add($k)
    }
}
foreach ($k in $mcpKeys) { [void]$forwardKeys.Add($k) }

# Build the -e flag list.
# For CWC_* keys: read ONLY from process env (one-shot shell override) -- never from
# project .env, even though they're in $forwardKeys (the explicit Adds above seed
# them so user-config-derived $env:CWC_* values still get forwarded into the container).
# For everything else: project .env first, then process env.
$forwardFlags = @()
$forwardedSummary = @()
foreach ($k in $forwardKeys) {
    $v = $null
    if ($k -like 'CWC_*') {
        if (Test-Path "Env:$k") { $v = (Get-Item "Env:$k").Value }
    } else {
        if ($dotenv.ContainsKey($k)) { $v = $dotenv[$k] }
        elseif (Test-Path "Env:$k") { $v = (Get-Item "Env:$k").Value }
    }
    if ($null -ne $v -and $v -ne '') {
        $forwardFlags += @('-e', "$k=$v")
        # Mask secrets in the summary print.
        $masked = if ($k -match 'KEY|TOKEN|SECRET|PASSWORD') { '***' } else { $v }
        $forwardedSummary += "$k=$masked"
    }
}

# 5. Acquire image: pull (default) or build (when -Build or no Dockerfile beside us)
# Image reference can be overridden via CWC_IMAGE; default points at the public Docker Hub repo.
$cwcImage = if ($env:CWC_IMAGE) { $env:CWC_IMAGE } else { 'fcostoya/claude-win-container:latest' }
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
        Write-Host "Image $cwcImage not found locally -- pulling from Docker Hub..." -ForegroundColor Cyan
    } else {
        Write-Host "Pulling $cwcImage..." -ForegroundColor Cyan
    }
    & docker pull $cwcImage
    if ($LASTEXITCODE -ne 0) {
        if ($haveLocalDockerfile) {
            Write-Host "Pull failed -- falling back to local build." -ForegroundColor Yellow
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
# Lead with a one-line image banner so users always know which version they're
# running and whether it's the latest stable. CWC_SKIP_VERSION_CHECK=1 disables
# the network call (used in CI / offline / tests).
$cwcClass = Get-CwcImageClassification $cwcImage
$bannerColor = 'DarkGray'
$bannerText  = $null
switch ($cwcClass.kind) {
    'dev' {
        # The `cwc dev` block already prints its own [cwc dev] banner, so suppress
        # this one to avoid double-banner noise.
        $bannerText = $null
    }
    'latest-tag' {
        $bannerText  = "[cwc] image: $cwcImage (latest stable)"
        $bannerColor = 'Green'
    }
    'preview-moving' {
        $bannerText  = "[cwc] image: $cwcImage (preview build, latest)"
        $bannerColor = 'Magenta'
    }
    'preview-pinned' {
        $verNote = if ($cwcClass.version) { " of $($cwcClass.version)" } else { '' }
        $bannerText  = "[cwc] image: $cwcImage (preview build${verNote}, pinned)"
        $bannerColor = 'Magenta'
    }
    'stable' {
        if ($env:CWC_SKIP_VERSION_CHECK -eq '1') {
            $bannerText  = "[cwc] image: $cwcImage (stable; version-check skipped)"
            $bannerColor = 'DarkGray'
        } else {
            $latestStable = Get-CwcLatestStableVersion
            if (-not $latestStable) {
                $bannerText  = "[cwc] image: $cwcImage (stable; version-check unavailable)"
                $bannerColor = 'DarkGray'
            } else {
                $cur = [version]$cwcClass.version
                $lat = [version]$latestStable
                if ($cur -eq $lat) {
                    $bannerText  = "[cwc] image: $cwcImage (stable, latest)"
                    $bannerColor = 'Green'
                } elseif ($cur -lt $lat) {
                    $bannerText  = "[cwc] image: $cwcImage (stable, outdated -- $latestStable is available)"
                    $bannerColor = 'Yellow'
                } else {
                    # Running ahead of the published latest -- typically during a release window.
                    $bannerText  = "[cwc] image: $cwcImage (stable, ahead of published $latestStable)"
                    $bannerColor = 'DarkGray'
                }
            }
        }
    }
    'custom' {
        $bannerText  = "[cwc] image: $cwcImage (custom tag)"
        $bannerColor = 'DarkGray'
    }
}
if ($bannerText) {
    Write-Host ""
    Write-Host $bannerText -ForegroundColor $bannerColor
}

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
