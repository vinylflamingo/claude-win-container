# Container entrypoint. Runs once per container start, then execs the CMD.
# Idempotent -- safe to re-run.

$ErrorActionPreference = 'Continue'

# Trust the bind-mounted workspace as a git repo (UID/owner mismatch otherwise blocks git ops)
& git config --global --add safe.directory C:/workspace 2>$null
& git config --global core.autocrlf input 2>$null
& git config --global core.longpaths true 2>$null

# Ensure persistent dirs exist (bind mounts are empty on first run)
foreach ($dir in @('C:\claude-data', 'C:\command-history', 'C:\claude-auth')) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

# JSON / hashtable helpers used by the settings.json deep-merge below.
# ConvertFrom-Json on Windows PowerShell 5.1 returns PSCustomObject; we recursively
# convert to hashtables so we can mutate cleanly and detect "is this a dict?" with
# a single type check.
function ConvertTo-CwcHashtable($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [hashtable]) {
        $h = @{}
        foreach ($k in $obj.Keys) { $h[$k] = ConvertTo-CwcHashtable $obj[$k] }
        return $h
    }
    if ($obj -is [System.Collections.IList] -and -not ($obj -is [string])) {
        return @($obj | ForEach-Object { ConvertTo-CwcHashtable $_ })
    }
    if ($obj -is [PSCustomObject]) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) {
            $h[$p.Name] = ConvertTo-CwcHashtable $p.Value
        }
        return $h
    }
    return $obj
}

function Read-CwcJsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return $null }
        return ConvertTo-CwcHashtable ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Host "[cwc] warning: failed to parse JSON at $path ($($_.Exception.Message))" -ForegroundColor Yellow
        return $null
    }
}

function Write-CwcJsonFile([string]$path, $obj) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    ($obj | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $path -Encoding UTF8
}

# Deep-merge two hashtables. $override wins at every level. Lists are treated as
# scalars (override replaces base entirely; no element-level merging -- semantics get
# weird, and Claude's settings shape doesn't need it).
function Merge-CwcDeep($base, $override) {
    if ($null -eq $override) { return $base }
    if ($null -eq $base)     { return $override }
    if (-not ($base -is [hashtable]) -or -not ($override -is [hashtable])) {
        return $override
    }
    $out = @{}
    foreach ($k in $base.Keys)     { $out[$k] = $base[$k] }
    foreach ($k in $override.Keys) {
        if ($out.ContainsKey($k) -and ($out[$k] -is [hashtable]) -and ($override[$k] -is [hashtable])) {
            $out[$k] = Merge-CwcDeep $out[$k] $override[$k]
        } else {
            $out[$k] = $override[$k]
        }
    }
    return $out
}

# Compute the delta of $current relative to $base. Returns a hashtable containing
# only keys that are added or changed in $current. Deletions are NOT represented --
# acceptable here because (1) the agent persistence threat is additive (writing
# new keys), not deletive, and (2) "delete a global setting from this project" is
# a feature we don't need in v1.
function Get-CwcDelta($base, $current) {
    if ($null -eq $current) { return $null }
    if ($null -eq $base)    { return $current }
    if (-not ($base -is [hashtable]) -or -not ($current -is [hashtable])) {
        if (($base | ConvertTo-Json -Depth 16 -Compress) -eq ($current | ConvertTo-Json -Depth 16 -Compress)) {
            return $null
        }
        return $current
    }
    $delta = @{}
    foreach ($k in $current.Keys) {
        if (-not $base.ContainsKey($k)) {
            $delta[$k] = $current[$k]
        } elseif (($base[$k] -is [hashtable]) -and ($current[$k] -is [hashtable])) {
            $sub = Get-CwcDelta $base[$k] $current[$k]
            if ($null -ne $sub -and $sub.Count -gt 0) { $delta[$k] = $sub }
        } else {
            $bj = if ($null -ne $base[$k])    { $base[$k]    | ConvertTo-Json -Depth 16 -Compress } else { $null }
            $cj = if ($null -ne $current[$k]) { $current[$k] | ConvertTo-Json -Depth 16 -Compress } else { $null }
            if ($bj -ne $cj) { $delta[$k] = $current[$k] }
        }
    }
    return $delta
}

# Auth-vs-project state split. Two binds, narrow sync surface:
#
# C:\claude-auth   -- global bind, shared across projects.
#                    Contains ONLY: .credentials.json (OAuth tokens, refreshed by Claude),
#                    mcp-needs-auth-cache.json (small cache), settings.json (global prefs).
#
# C:\claude-data   -- per-project bind. Where Claude actually reads/writes everything from.
#                    Includes: per-project sessions, todos, plans, history.jsonl,
#                    plugins/, cache/, statsig/, telemetry/, settings-project.json (overlay).
#                    Plugins and caches used to be global; making them per-project closes
#                    the cross-project agent-persistence vector (project A's agent could
#                    plant a plugin that ran in project B's container).
#
# settings.json is special: it's deep-merged at entry (global + per-project overlay),
# and on exit we deep-diff the result vs. the global baseline and write only the delta
# to the per-project overlay (settings-project.json). Global is never mutated by sessions.
# (See Phase 3 of the security plan; docs/security.md.)
#
# Why copy and not junction? Windows containers don't permit creating reparse points
# (junctions / symlinks) inside bind-mounted directories -- the host filesystem rejects
# them with "Access is denied." So we copy in-and-out. Cost is small.
$authRoot = 'C:\claude-auth'
$dataRoot = 'C:\claude-data'

# Whole-file global sync (bytes-identical between binds on entry + exit).
$globalFiles = @(
    '.credentials.json',
    'mcp-needs-auth-cache.json'
)

# Copy whole-file globals: auth -> data.
foreach ($f in $globalFiles) {
    $src = Join-Path $authRoot $f
    $dst = Join-Path $dataRoot $f
    if (Test-Path $src) {
        try { Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop } catch { }
    }
}

# settings.json deep-merge.
# Global baseline -> C:\claude-auth\settings.json (theme, telemetry, autoUpdater, ...).
# Per-project overlay -> C:\claude-data\settings-project.json (mcpServers, hooks,
# permissions, env, anything project-scoped).
# Result Claude reads -> C:\claude-data\settings.json (merged; project wins on conflict).
$globalSettings  = Read-CwcJsonFile (Join-Path $authRoot 'settings.json')
$overlaySettings = Read-CwcJsonFile (Join-Path $dataRoot 'settings-project.json')
$mergedSettings  = Merge-CwcDeep $globalSettings $overlaySettings
if ($null -ne $mergedSettings) {
    Write-CwcJsonFile (Join-Path $dataRoot 'settings.json') $mergedSettings
} else {
    # Neither global nor overlay exists; remove any stale merged file so Claude sees
    # a clean state.
    Remove-Item -LiteralPath (Join-Path $dataRoot 'settings.json') -Force -ErrorAction SilentlyContinue
}
# Snapshot the global baseline for the exit-time delta computation. We deliberately
# diff against global (not the merged result) so that anything different from global
# -- whether already in the overlay or newly written this session -- flows back into
# the per-project overlay, never into global.
$script:cwcSettingsBaseline = $globalSettings

# LAN-egress lockdown.
# Block lateral movement from the container to the host's LAN. Outbound to RFC1918 and
# IPv6 ULA / link-local destinations is blackholed via the routing table; public internet
# stays reachable. The container's own docker subnet remains reachable because the existing
# more-specific route wins the routing decision.
#
# Caveat: this is "good faith" defense. Code running as Administrator inside the container
# could `Remove-NetRoute` and re-enable LAN access. The point is to prevent surprises
# (an MCP server scanning 192.168.x.x, claude trying to ssh somewhere on the LAN), not to
# resist a determined attacker.
#
# Override:
#   CWC_LOCKDOWN_LAN=0          disable the lockdown entirely
#   CWC_ALLOW_NETS=cidr,cidr,...  re-allow specific subnets (e.g. "192.168.50.0/24")
if ($env:CWC_LOCKDOWN_LAN -ne '0') {
    $primary = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -First 1
    if ($primary) {
        $idx = $primary.InterfaceIndex
        $defaultGw = (Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        $blocked = @()
        foreach ($cidr in @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16')) {
            try {
                New-NetRoute -DestinationPrefix $cidr -InterfaceIndex $idx -NextHop '0.0.0.0' -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                $blocked += $cidr
            } catch { }
        }
        foreach ($cidr in @('fe80::/10', 'fc00::/7')) {
            try {
                New-NetRoute -DestinationPrefix $cidr -InterfaceIndex $idx -NextHop '::' -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                $blocked += $cidr
            } catch { }
        }

        $allowed = @()
        if ($env:CWC_ALLOW_NETS -and $defaultGw) {
            foreach ($cidr in $env:CWC_ALLOW_NETS.Split(',')) {
                $cidr = $cidr.Trim()
                if (-not $cidr) { continue }
                try {
                    New-NetRoute -DestinationPrefix $cidr -InterfaceIndex $idx -NextHop $defaultGw -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                    $allowed += $cidr
                } catch { Write-Host "[cwc] LAN allow failed for ${cidr}: $_" }
            }
        }
        if ($blocked.Count -gt 0) {
            Write-Host "[cwc] LAN egress: blocked $($blocked -join ', ')$(if ($allowed) { ' (re-allowed ' + ($allowed -join ', ') + ')' })"
        }
    }
}

# Validators duplicated from cwc.ps1's Test-CwcFqdn / Test-CwcHostTarget. Defense in
# depth -- if config was hand-edited to bypass the launcher's validation, we still
# refuse to write garbage into the hosts file. KEEP IN SYNC with cwc.ps1.
$script:cwcFqdnRegex = '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
function Test-EntrypointFqdn([string]$fqdn) {
    if (-not $fqdn) { return $false }
    if ($fqdn.Length -gt 253) { return $false }
    return $fqdn.ToLowerInvariant() -match $script:cwcFqdnRegex
}
function Test-EntrypointHostTarget([string]$target) {
    if (-not $target) { return $false }
    if ($target -eq 'host-gateway') { return $true }
    if ($target -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $octets = $target.Split('.') | ForEach-Object { [int]$_ }
        return -not ($octets | Where-Object { $_ -gt 255 })
    }
    if ($target -match '^[0-9a-fA-F:]+$' -and $target.Contains(':')) { return $true }
    return $false
}
# Default Anthropic-auth-channel denylist. Hardcoded here so the entrypoint refuses
# to redirect these FQDNs even if config bypassed the launcher's denylist check.
$script:cwcEntrypointDenylist = @(
    '*.anthropic.com', 'anthropic.com',
    '*.claude.ai',     'claude.ai',
    '*.claude.com',    'claude.com',
    '*.anthropic.ai',  'anthropic.ai'
)
function Test-EntrypointFqdnDenied([string]$fqdn) {
    if (-not $fqdn) { return $false }
    $lower = $fqdn.ToLowerInvariant()
    foreach ($pattern in $script:cwcEntrypointDenylist) {
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

# Extra hosts (FQDN -> IP / host-gateway).
# CWC_EXTRA_HOSTS=fqdn:target,fqdn:target -- written by the launcher from `cwc firewall
# host-add`. We append to the container's hosts file at runtime.
#
# `host-gateway` is resolved to whatever `host.docker.internal` points to (Docker for
# Windows pre-populates that name to the host's vNIC on the bridge). We use the entrypoint
# instead of compose's `extra_hosts: host-gateway` because the latter doesn't reliably
# resolve in `docker compose run` and requires daemon-level configuration.
#
# IMPORTANT: when host-gateway resolves to an RFC1918 IP (commonly does), we have to add
# a /32 allow-route through the lockdown so the mapping is actually reachable, not just
# resolvable. Without this, DNS returns the IP but TCP gets blackholed.
if ($env:CWC_EXTRA_HOSTS) {
    $hostsFile = 'C:\Windows\System32\drivers\etc\hosts'
    $gatewayIp = $null
    try {
        $gatewayIp = (Resolve-DnsName -Name 'host.docker.internal' -Type A -ErrorAction Stop |
                      Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
    } catch { }

    $primaryHost = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -First 1
    $hostIdx = if ($primaryHost) { $primaryHost.InterfaceIndex } else { $null }
    $hostDefaultGw = if ($hostIdx) {
        (Get-NetRoute -InterfaceIndex $hostIdx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
    } else { $null }

    # Parse CWC_EXTRA_HOSTS. Two formats accepted:
    #   New (Phase 4):  "fqdn|target|port,port;fqdn|target|ports"
    #   Old (legacy):   "fqdn:target,fqdn:target"  (defaults ports to 443,80)
    $rawEntries = if ($env:CWC_EXTRA_HOSTS.Contains(';') -or $env:CWC_EXTRA_HOSTS.Contains('|')) {
        $env:CWC_EXTRA_HOSTS.Split(';')
    } else {
        # Old comma-separated format -- preserve compat for one-shot env overrides.
        $env:CWC_EXTRA_HOSTS.Split(',')
    }

    # netsh portproxy depends on the IP Helper service (iphlpsvc), which on Server
    # Core base images ships disabled. Start it before we issue any portproxy add,
    # otherwise every add fails silently and we lose the per-port narrowing. If we
    # can't start it (e.g. service genuinely missing), fall back per-entry to the
    # legacy direct-mapping (hosts file points at the gateway IP, /32 allow-route
    # for the gateway, all ports reachable). Functionality preserved, narrowing lost.
    $portproxyAvailable = $true
    try {
        $svc = Get-Service iphlpsvc -ErrorAction Stop
        if ($svc.StartType -eq 'Disabled') {
            Set-Service iphlpsvc -StartupType Manual -ErrorAction SilentlyContinue
        }
        if ($svc.Status -ne 'Running') {
            Start-Service iphlpsvc -ErrorAction Stop
        }
    } catch {
        $portproxyAvailable = $false
        Write-Host "[cwc] iphlpsvc unavailable ($($_.Exception.Message)); falling back to legacy hosts mapping (no per-port narrowing)" -ForegroundColor Yellow
    }

    # Per-FQDN loopback IP allocation. The hosts file maps fqdn -> 127.0.0.<n>; portproxy
    # forwards listen 127.0.0.<n>:port to target:port. Ports not listed aren't bound on
    # the loopback and so are unreachable via the FQDN. (Direct-IP-to-target on other
    # ports is still possible -- the /32 allow-route below is necessarily all-ports;
    # see docs/security.md for that limitation.)
    $loopbackCounter = 2

    $added = @()
    $skipped = @()
    $pokedIPs = @{}
    foreach ($entry in $rawEntries) {
        $entry = $entry.Trim()
        if (-not $entry) { continue }

        # Detect format and parse.
        if ($entry.Contains('|')) {
            $parts = $entry.Split('|', 3)
            if ($parts.Count -lt 2) { continue }
            $fqdn   = $parts[0].Trim()
            $target = $parts[1].Trim()
            $ports  = if ($parts.Count -ge 3 -and $parts[2]) {
                @($parts[2].Split(',') | ForEach-Object {
                    $n = 0
                    if ([int]::TryParse($_.Trim(), [ref]$n) -and $n -gt 0 -and $n -le 65535) { $n }
                })
            } else { @(443, 80) }
        } else {
            $parts = $entry.Split(':', 2)
            if ($parts.Count -lt 2) { continue }
            $fqdn   = $parts[0].Trim()
            $target = $parts[1].Trim()
            $ports  = @(443, 80)
        }

        # Validate before doing anything else -- defense in depth against config bypass.
        if (-not (Test-EntrypointFqdn $fqdn)) {
            $skipped += "$fqdn (invalid FQDN format)"
            continue
        }
        if (-not (Test-EntrypointHostTarget $target)) {
            $skipped += "$fqdn (invalid target '$target')"
            continue
        }
        if (Test-EntrypointFqdnDenied $fqdn) {
            $skipped += "$fqdn (denylisted -- would redirect Anthropic auth traffic)"
            continue
        }
        if ($ports.Count -eq 0) {
            $skipped += "$fqdn (no valid ports)"
            continue
        }

        # Resolve host-gateway -> actual IP.
        $resolved = $target
        if ($target -eq 'host-gateway') {
            if (-not $gatewayIp) {
                $skipped += "$fqdn (host-gateway unresolvable)"
                continue
            }
            $resolved = $gatewayIp
        }

        # Try the portproxy path: per-FQDN loopback, narrowed by listen port set.
        $portsApplied = @()
        $loopback     = $null
        if ($portproxyAvailable) {
            $loopback = "127.0.0.$loopbackCounter"
            $loopbackCounter++
            foreach ($p in $ports) {
                $proxyArgs = @(
                    'interface', 'portproxy', 'add', 'v4tov4',
                    "listenport=$p", "listenaddress=$loopback",
                    "connectport=$p", "connectaddress=$resolved"
                )
                $null = & netsh @proxyArgs 2>&1
                if ($LASTEXITCODE -eq 0) { $portsApplied += $p }
            }
        }

        # Decide whether to use the portproxy path or fall back to direct mapping.
        $useProxy = $portproxyAvailable -and $portsApplied.Count -gt 0
        $hostsTarget = if ($useProxy) { $loopback } else { $resolved }

        if (-not $portproxyAvailable -and $loopbackCounter -eq 2) {
            # First fallback entry -- no banner repetition needed.
        } elseif (-not $useProxy) {
            $added += "$fqdn -> $resolved (fallback: portproxy unavailable, all ports reachable)"
        }

        # Hosts file mapping (idempotent).
        $existing = Select-String -Path $hostsFile -Pattern "^\s*\S+\s+$([regex]::Escape($fqdn))\s*$" -ErrorAction SilentlyContinue
        if (-not $existing) {
            Add-Content -LiteralPath $hostsFile -Value "$hostsTarget`t$fqdn"
        }
        if ($useProxy) {
            $added += "$fqdn -> $loopback ($resolved port(s) $($portsApplied -join ','))"
        }

        # Poke /32 hole through the lockdown so traffic to the resolved target IP
        # (whether portproxy's outbound connect or the agent's direct connect in
        # the fallback case) isn't blackholed. Necessarily all-ports -- see
        # docs/security.md for the limitation.
        $isPrivate = $resolved -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)'
        if ($isPrivate -and $hostIdx -and $hostDefaultGw -and -not $pokedIPs.ContainsKey($resolved)) {
            try {
                New-NetRoute -DestinationPrefix "$resolved/32" -InterfaceIndex $hostIdx -NextHop $hostDefaultGw -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                $pokedIPs[$resolved] = $true
            } catch { }
        }
    }
    if ($added.Count -gt 0) {
        Write-Host "[cwc] hosts: $($added -join ', ')"
    }
    if ($skipped.Count -gt 0) {
        Write-Host "[cwc] hosts skipped: $($skipped -join ', ')"
    }
}

# Harden -- opt-in tamper-resistant watchdog.
# When CWC_HARDEN=1 we snapshot the routing/hosts/CA state we just set up and spawn
# a PowerShell background job that re-applies it every 2s. We use Start-Job (in-process
# runspace) instead of Start-Process because the latter is unreliable in Server Core
# containers -- `-WindowStyle Hidden` requires a GUI subsystem that doesn't exist there,
# and detaching from the parent has surprises. Start-Job uses PowerShell's own job
# system, which is built for exactly this kind of long-running background work.
#
# The agent has admin in the container and can still defeat this with effort (Stop-Job,
# Remove-Job, kill the runspace). The goal is to raise the bar from "Remove-NetRoute"
# to multiple deliberate steps, not provide isolation. See docs/security.md.
$watchdogJob = $null
if ($env:CWC_HARDEN -eq '1' -and $env:CWC_LOCKDOWN_LAN -ne '0') {
    $watchdogDir = 'C:\cwc-watchdog'
    if (-not (Test-Path $watchdogDir)) {
        New-Item -ItemType Directory -Force -Path $watchdogDir | Out-Null
    }
    $logPath = Join-Path $watchdogDir 'watchdog.log'

    # Collect snapshot state. Some variables (like $idx, $blocked) only exist if the
    # lockdown actually applied; default safely if they're missing.
    $jobState = @{
        interface_index = if ($idx) { [int]$idx } else { 0 }
        default_gateway = if ($defaultGw) { [string]$defaultGw } else { '' }
        blackhole_cidrs = if ($blocked)   { @($blocked) }   else { @() }
        pinhole_cidrs   = if ($pokedIPs)  { @($pokedIPs.Keys | ForEach-Object { "$_/32" }) } else { @() }
        allow_cidrs     = if ($allowed)   { @($allowed) }   else { @() }
        hosts_path      = 'C:\Windows\System32\drivers\etc\hosts'
        hosts_expected  = if (Test-Path 'C:\Windows\System32\drivers\etc\hosts') {
            Get-Content -LiteralPath 'C:\Windows\System32\drivers\etc\hosts' -Raw
        } else { '' }
        ca_thumbprints  = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
                            Select-Object -ExpandProperty Thumbprint)
        log_path        = $logPath
    }

    try {
        $watchdogJob = Start-Job -Name 'cwc-watchdog' -ArgumentList @($jobState) -ScriptBlock {
            param($s)
            $ErrorActionPreference = 'SilentlyContinue'

            # Import the modules we need explicitly. PowerShell auto-loading is
            # sometimes unreliable in job runspaces (depends on PSModuleAutoLoading
            # preference + module path resolution in the child runspace).
            Import-Module NetTCPIP -ErrorAction SilentlyContinue
            Import-Module NetAdapter -ErrorAction SilentlyContinue

            $ifIdx        = [int]$s.interface_index
            $gw           = [string]$s.default_gateway
            $blackholes   = @($s.blackhole_cidrs)
            $pinholes     = @($s.pinhole_cidrs)
            $allowCidrs   = @($s.allow_cidrs)
            $hostsPath    = [string]$s.hosts_path
            $hostsExpect  = [string]$s.hosts_expected
            $caBaseline   = @($s.ca_thumbprints)
            $logPath      = [string]$s.log_path

            function Write-WatchdogLog([string]$msg) {
                "$(Get-Date -Format o)  $msg" | Add-Content -LiteralPath $logPath
            }

            # Write a startup heartbeat immediately so we can verify the job is
            # alive even if the loop body errors. Useful for diagnostics.
            Write-WatchdogLog "watchdog runspace booted (PID=$PID, ifIdx=$ifIdx)"

            function Test-RouteIsAllowedNonBlackhole([string]$prefix) {
                if ($prefix -eq '0.0.0.0/0' -or $prefix -eq '::/0') { return $true }
                if ($pinholes -contains $prefix) { return $true }
                if ($allowCidrs -contains $prefix) { return $true }
                return $false
            }

            function Test-IsRfc1918([string]$prefix) {
                $ip = $prefix.Split('/')[0]
                return $ip -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)' `
                    -or $ip -match '^fe80:|^fc|^fd'
            }

            Write-WatchdogLog "watchdog started (ifIdx=$ifIdx blackholes=$($blackholes -join ',') pinholes=$($pinholes -join ','))"

            while ($true) {
                try {
                    # 1. Re-apply blackhole routes that have been removed or pointed elsewhere.
                    foreach ($cidr in $blackholes) {
                        $isV6 = $cidr.Contains(':')
                        $expected = if ($isV6) { '::' } else { '0.0.0.0' }
                        $r = Get-NetRoute -DestinationPrefix $cidr -ErrorAction SilentlyContinue | Select-Object -First 1
                        if (-not $r -or $r.NextHop -ne $expected) {
                            try {
                                if ($r) {
                                    Remove-NetRoute -DestinationPrefix $cidr -InterfaceIndex $ifIdx -Confirm:$false -ErrorAction SilentlyContinue
                                }
                                New-NetRoute -DestinationPrefix $cidr -InterfaceIndex $ifIdx -NextHop $expected `
                                    -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                                Write-WatchdogLog "re-applied blackhole $cidr"
                            } catch { Write-WatchdogLog "FAILED to re-apply blackhole $cidr : $($_.Exception.Message)" }
                        }
                    }

                    # 2. Remove unauthorized allow-routes to RFC1918 / link-local.
                    $existing = Get-NetRoute -InterfaceIndex $ifIdx -ErrorAction SilentlyContinue
                    foreach ($r in $existing) {
                        $prefix = [string]$r.DestinationPrefix
                        if (-not $prefix) { continue }
                        $nh = [string]$r.NextHop
                        if ($nh -eq '0.0.0.0' -or $nh -eq '::') { continue }
                        if (Test-RouteIsAllowedNonBlackhole $prefix) { continue }
                        if (-not (Test-IsRfc1918 $prefix)) { continue }
                        try {
                            Remove-NetRoute -DestinationPrefix $prefix -InterfaceIndex $ifIdx -Confirm:$false -ErrorAction Stop
                            Write-WatchdogLog "removed unauthorized route $prefix -> $nh"
                        } catch { }
                    }

                    # 3. Restore hosts file content if changed.
                    $current = Get-Content -LiteralPath $hostsPath -Raw -ErrorAction SilentlyContinue
                    if ($current -ne $hostsExpect) {
                        try {
                            Set-Content -LiteralPath $hostsPath -Value $hostsExpect -NoNewline -Force -ErrorAction Stop
                            Write-WatchdogLog "hosts file restored from snapshot"
                        } catch { Write-WatchdogLog "FAILED to restore hosts file: $($_.Exception.Message)" }
                    }

                    # 4. Log new entries in the trust store.
                    $currentCAs = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
                                    Select-Object -ExpandProperty Thumbprint)
                    $newCAs = @($currentCAs | Where-Object { $caBaseline -notcontains $_ })
                    if ($newCAs.Count -gt 0) {
                        foreach ($t in $newCAs) { Write-WatchdogLog "NEW root CA installed: thumbprint=$t" }
                        $caBaseline = $currentCAs
                    }
                } catch {
                    Write-WatchdogLog "watchdog loop error: $($_.Exception.Message)"
                }
                Start-Sleep -Seconds 2
            }
        } -ErrorAction Stop
        Write-Host "[cwc] harden: watchdog job started (id=$($watchdogJob.Id), log=$logPath)" -ForegroundColor Yellow
    } catch {
        Write-Host "[cwc] harden: failed to start watchdog job ($($_.Exception.Message))" -ForegroundColor Red
        $watchdogJob = $null
    }
} elseif ($env:CWC_HARDEN -eq '1' -and $env:CWC_LOCKDOWN_LAN -eq '0') {
    Write-Host "[cwc] harden requested but LOCKDOWN_LAN=0 -- nothing to defend, watchdog skipped." -ForegroundColor Yellow
}

# Hand off to the CMD (claude, powershell, etc.)
# A subtle PowerShell gotcha here: PowerShell unwraps single-element arrays when an
# `if`-expression's value is assigned to a variable. So `$rest = if(...) { @($x) }` becomes
# a scalar string when there's exactly one trailing arg -- `@$rest` then splats character-by-
# character (so `--version` becomes `-`, `-`, `v`, `e`, ...). Splitting the assignment per
# branch sidesteps the unwrap.
if ($args.Count -gt 0) {
    $cmd = $args[0]
    if ($args.Count -gt 1) {
        $rest = @($args[1..($args.Count - 1)])
    } else {
        $rest = @()
    }
    & $cmd @rest
    $exitCode = $LASTEXITCODE
} else {
    & powershell
    $exitCode = $LASTEXITCODE
}

# Stop the harden watchdog cleanly. The container shuts down right after, but
# explicit cleanup is friendlier and lets us surface any final job output.
if ($watchdogJob) {
    try {
        Stop-Job -Job $watchdogJob -ErrorAction SilentlyContinue
        Remove-Job -Job $watchdogJob -Force -ErrorAction SilentlyContinue
    } catch { }
}

# On exit:
#   1. Copy whole-file globals (auth tokens, MCP-auth cache) data -> auth so the
#      next session sees refreshed tokens.
#   2. Compute the delta between this session's settings.json and the global
#      baseline; write the delta to the per-project overlay. NEVER touch global
#      settings.json from a session -- that's how project A's agent persisted into
#      project B's session in the old design.
#   3. Plugins/caches are no longer synced. They're per-project; Claude regenerates
#      caches as needed, plugins live in the per-project bind.
foreach ($f in $globalFiles) {
    $src = Join-Path $dataRoot $f
    $dst = Join-Path $authRoot $f
    if (Test-Path $src) {
        try { Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop } catch { }
    }
}

$finalSettings = Read-CwcJsonFile (Join-Path $dataRoot 'settings.json')
$overlayPath   = Join-Path $dataRoot 'settings-project.json'
if ($null -ne $finalSettings) {
    $delta = Get-CwcDelta $script:cwcSettingsBaseline $finalSettings
    if ($null -ne $delta -and $delta.Count -gt 0) {
        Write-CwcJsonFile $overlayPath $delta
    } elseif (Test-Path -LiteralPath $overlayPath) {
        # No delta vs. global anymore -- clean up a stale overlay.
        Remove-Item -LiteralPath $overlayPath -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
