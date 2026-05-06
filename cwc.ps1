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
#   $env:CWC_IMAGE = 'fcostoya/claude-win-container:0.1.0-alpha'   # pin a version
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
    Write-Host "                             denylist {list|add|remove|reset}"
    Write-Host "                                                           manage FQDNs that host-add refuses"
    Write-Host "                                                           (defaults: anthropic.com / claude.ai etc.)"
    Write-Host "  mount <subcommand>       Manage extra bind mounts (Obsidian vaults, design specs, runbooks)."
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
    Write-Host "                           Toggle the tamper-resistant in-container watchdog. Off by"
    Write-Host "                           default; run 'cwc harden status' for what it does and the"
    Write-Host "                           trade-offs (also docs/security.md)."
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
# Stored at %USERPROFILE%\.cwc\config.json.
$cwcConfigDir  = Join-Path $env:USERPROFILE '.cwc'
$cwcConfigPath = Join-Path $cwcConfigDir 'config.json'

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
function Get-CwcProjectTrustState($cfg, [string]$slug, [string]$projectDir) {
    $trustedMap = @{}
    if ($cfg.trusted_files -and $cfg.trusted_files.ContainsKey($slug)) {
        $trustedMap = $cfg.trusted_files[$slug]
    }
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
        slug        = $slug
        files       = $files
        any_changed = $anyChanged
        any_present = $anyPresent
        first_run   = ($trustedMap.Count -eq 0)
    }
}

function Save-CwcProjectTrust($cfg, [string]$slug, [string]$projectDir) {
    if (-not $cfg.trusted_files) {
        $cfg | Add-Member -MemberType NoteProperty -Name trusted_files -Value @{} -Force
    }
    $map = @{}
    foreach ($name in $script:cwcTrustedFileNames) {
        $path = Join-Path $projectDir $name
        if (Test-Path -LiteralPath $path) {
            $hash = Get-FileSha256 $path
            if ($hash) { $map[$name] = $hash }
        }
    }
    $cfg.trusted_files[$slug] = $map
    Write-CwcConfig $cfg
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

function Read-CwcConfig {
    if (-not (Test-Path $cwcConfigPath)) {
        return [pscustomobject]@{
            lockdown_lan   = $true
            allow_nets     = @()
            extra_hosts    = @{}
            mounts         = @{}
            host_denylist  = @(Get-CwcDefaultDenylist)
            trusted_files  = @{}
            harden_enabled = $false
        }
    }
    $raw = Get-Content -LiteralPath $cwcConfigPath -Raw
    $json = $raw | ConvertFrom-Json
    # JSON objects deserialise to PSCustomObject; convert nested ones to hashtables for mutation.
    # extra_hosts schema: each value is { target = '<host-gateway|ip>', ports = @(<int>...) }.
    # Old schema (pre-Phase 4) used a bare string target -- we migrate inline (default ports 443,80)
    # and emit a one-time banner when we first detect the migration.
    $hosts = @{}
    $script:cwcMigratedHostPorts = $false
    if ($json.extra_hosts) {
        foreach ($p in $json.extra_hosts.PSObject.Properties) {
            $val = $p.Value
            if ($val -is [string]) {
                # Old format: bare string target, no ports -- grandfather to 443,80.
                $hosts[$p.Name] = @{ target = [string]$val; ports = @(443, 80) }
                $script:cwcMigratedHostPorts = $true
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
    $denylist = if ($null -ne $json.host_denylist) {
        @($json.host_denylist) | Where-Object { $_ }
    } else {
        # Existing config without host_denylist field -- populate with defaults.
        @(Get-CwcDefaultDenylist)
    }
    # Per-project file-trust hashes. JSON deserialises nested objects as PSCustomObject;
    # convert to nested hashtables so the trust subcommand can mutate cleanly.
    $trustedFiles = @{}
    if ($json.trusted_files) {
        foreach ($p in $json.trusted_files.PSObject.Properties) {
            $perProject = @{}
            if ($p.Value) {
                foreach ($q in $p.Value.PSObject.Properties) {
                    $perProject[$q.Name] = [string]$q.Value
                }
            }
            $trustedFiles[$p.Name] = $perProject
        }
    }
    return [pscustomobject]@{
        lockdown_lan   = if ($null -ne $json.lockdown_lan) { [bool]$json.lockdown_lan } else { $true }
        allow_nets     = @($json.allow_nets) | Where-Object { $_ }
        extra_hosts    = $hosts
        mounts         = $mounts
        host_denylist  = $denylist
        trusted_files  = $trustedFiles
        harden_enabled = if ($null -ne $json.harden_enabled) { [bool]$json.harden_enabled } else { $false }
    }
}

function Write-CwcConfig($cfg) {
    if (-not (Test-Path $cwcConfigDir)) { New-Item -ItemType Directory -Force -Path $cwcConfigDir | Out-Null }
    $trustedFiles = if ($cfg.trusted_files) { $cfg.trusted_files } else { @{} }
    @{
        lockdown_lan   = [bool]$cfg.lockdown_lan
        allow_nets     = @($cfg.allow_nets)
        extra_hosts    = $cfg.extra_hosts
        mounts         = $cfg.mounts
        host_denylist  = @($cfg.host_denylist)
        trusted_files  = $trustedFiles
        harden_enabled = [bool]$cfg.harden_enabled
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cwcConfigPath
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
                    $entry = $cfg.extra_hosts[$fqdn]
                    Write-Host "    $fqdn -> $($entry.target)  ports=$($entry.ports -join ',')"
                }
            } else {
                Write-Host "  Host mappings: (none)"
            }
            $hardenStateLabel = if ($cfg.harden_enabled) { 'enabled' } else { 'disabled' }
            Write-Host "  Harden       : $hardenStateLabel"
            Write-Host "  Config file  : $cwcConfigPath"
            Write-Host ""
            Write-Host "  Shell env CWC_* (one-shot) overrides this config; project .env does not." -ForegroundColor DarkGray
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
            if (Test-CwcFqdnDenied -fqdn $arg -denylist @($cfg.host_denylist)) {
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
            Write-CwcConfig $cfg
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
                Write-CwcConfig $cfg
                Write-Host "Removed: $arg" -ForegroundColor Yellow
            } else {
                Write-Host "$arg was not mapped." -ForegroundColor DarkGray
            }
        }
        'denylist' {
            $sub2 = if ($Cmd.Count -ge 3) { $Cmd[2] } else { 'list' }
            $denyArg = if ($Cmd.Count -ge 4) { $Cmd[3] } else { $null }
            $denylist = @($cfg.host_denylist)
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
                        $cfg.host_denylist = @($denylist) + $pattern
                        Write-CwcConfig $cfg
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
                        $cfg.host_denylist = $newList
                        Write-CwcConfig $cfg
                        Write-Host "Removed: $pattern" -ForegroundColor Yellow
                    } else {
                        Write-Host "$pattern not in denylist." -ForegroundColor DarkGray
                    }
                }
                'reset' {
                    $cfg.host_denylist = @(Get-CwcDefaultDenylist)
                    Write-CwcConfig $cfg
                    Write-Host "Denylist reset to defaults." -ForegroundColor Green
                }
                default {
                    Write-Host "Unknown denylist subcommand: $sub2" -ForegroundColor Red
                    Write-Host "Usage: cwc firewall denylist {list|add <pattern>|remove <pattern>|reset}"
                    exit 1
                }
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

# `cwc trust` / `cwc untrust` -- manage per-project file-trust hashes.
# Trust covers files that drive next-session policy: claude-sandbox.overlay.yml,
# .env, .mcp.json. The agent has RW on the workspace, so any of these can be edited
# from inside the container; trust forces the dev to ack changes before they take effect.
if ($Cmd -and $Cmd.Count -gt 0 -and ($Cmd[0] -eq 'trust' -or $Cmd[0] -eq 'untrust')) {
    if (-not $Force) {
        $isProjectRoot = (Test-Path '.git') -or (Test-Path 'package.json') -or `
                         (Test-Path '*.sln') -or (Test-Path '.mcp.json') -or `
                         (Test-Path 'pyproject.toml') -or (Test-Path 'go.mod') -or `
                         (Test-Path 'Cargo.toml')
        if (-not $isProjectRoot) {
            Write-Host ""
            Write-Host "  '$projectDir' doesn't look like a project root." -ForegroundColor Yellow
            Write-Host "  cwc trust operates per-project -- cd to a project directory first."
            Write-Host ""
            exit 1
        }
    }
    $slugForTrust = Get-ProjectSlug $projectDir
    $cfgForTrust  = Read-CwcConfig

    if ($Cmd[0] -eq 'untrust') {
        if ($cfgForTrust.trusted_files -and $cfgForTrust.trusted_files.ContainsKey($slugForTrust)) {
            $cfgForTrust.trusted_files.Remove($slugForTrust)
            Write-CwcConfig $cfgForTrust
            Write-Host "Removed trust for project: $projectDir" -ForegroundColor Yellow
            Write-Host "  Next 'cwc' run will re-prompt for trust."
        } else {
            Write-Host "No trust state recorded for: $projectDir" -ForegroundColor DarkGray
        }
        exit 0
    }

    # cwc trust [list]
    $trustSub = if ($Cmd.Count -ge 2) { $Cmd[1] } else { '' }
    $state = Get-CwcProjectTrustState $cfgForTrust $slugForTrust $projectDir
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
    Save-CwcProjectTrust $cfgForTrust $slugForTrust $projectDir | Out-Null
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
    $cfgForHarden = Read-CwcConfig
    switch ($hardenSub) {
        'enable' {
            if ($cfgForHarden.harden_enabled) {
                Write-Host "Harden already enabled." -ForegroundColor DarkGray
                exit 0
            }
            $cfgForHarden.harden_enabled = $true
            Write-CwcConfig $cfgForHarden
            Write-Host ""
            Write-Host "Harden enabled." -ForegroundColor Green
            Write-Host "  Next 'cwc' session will run with the in-container watchdog active."
            Write-Host "  See 'cwc harden status' for what gets enforced."
            Write-Host ""
        }
        'disable' {
            if (-not $cfgForHarden.harden_enabled) {
                Write-Host "Harden already disabled." -ForegroundColor DarkGray
                exit 0
            }
            $cfgForHarden.harden_enabled = $false
            Write-CwcConfig $cfgForHarden
            Write-Host "Harden disabled. Next 'cwc' session will run without the watchdog." -ForegroundColor Yellow
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

# 2b. Trust check -- workspace files that drive next-session policy
# (claude-sandbox.overlay.yml, .env, .mcp.json). The agent has RW in the workspace,
# so any of these can be agent-edited; we refuse to silently inherit those edits.
$cwcCfg = Read-CwcConfig
$trustState = Get-CwcProjectTrustState $cwcCfg $slug $projectDir
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
    Save-CwcProjectTrust $cwcCfg $slug $projectDir | Out-Null
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

# 4a. Apply user config (~/.cwc/config.json) to the firewall env vars.
# Config was already read above for the trust check; reuse it. The user config is
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

# One-time migration banner -- printed on the first session after upgrading from the
# pre-Phase-4 schema (bare-string targets, no per-port restriction). Re-saving the
# config in new format dismisses the banner permanently.
if ($script:cwcMigratedHostPorts) {
    Write-Host ""
    Write-Host "[cwc] Upgraded host-add entries to per-port schema (default ports 443,80)." -ForegroundColor Yellow
    Write-Host "[cwc] Run 'cwc firewall host-list' to review; 'cwc firewall host-add <fqdn> <target> <ports>'" -ForegroundColor DarkGray
    Write-Host "[cwc] to narrow further. Saving config in new format now." -ForegroundColor DarkGray
    Write-Host ""
    Write-CwcConfig $cwcCfg
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
# Shell env CWC_* still works (one-shot dev override); user config (~/.cwc/config.json)
# is the persistent source. (Phase 2 of the security plan; see docs/security.md.)
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
