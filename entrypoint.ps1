# Container entrypoint. Runs once per container start, then execs the CMD.
# Idempotent — safe to re-run.

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

# Auth-vs-project state split.
# C:\claude-auth   — global bind, shared across all projects (auth tokens, user prefs, plugins)
# C:\claude-data   — per-project bind (memory, sessions, todos, history)
#
# Claude reads CLAUDE_CONFIG_DIR (= C:\claude-data) for everything, so we MERGE the global
# files+dirs into the per-project dir at startup and copy modifications back on exit.
#
# Why copy and not junction? Windows containers don't permit creating reparse points (junctions
# / symlinks) inside bind-mounted directories — the host filesystem rejects them with "Access
# is denied." So we copy in-and-out instead. Cost is small (these dirs are < a few MB) and
# happens once per session start/end.
#
# What's "global":  .credentials.json, settings.json, plugins/, mcp-needs-auth-cache.json,
#                   cache/, statsig/, telemetry/, stats-cache.json
#                   (auth, user preferences, plugin installs, performance caches)
# What's "per-project": projects/, sessions/, todos/, tasks/, plans/, history.jsonl,
#                       file-history/, session-env/, shell-snapshots/
#                       (conversation state, session-bound data — handled by Claude itself)
$authRoot = 'C:\claude-auth'
$dataRoot = 'C:\claude-data'
$globalFiles = @(
    '.credentials.json',
    'settings.json',
    'mcp-needs-auth-cache.json',
    'stats-cache.json'
)
$globalDirs = @(
    'plugins',
    'cache',
    'statsig',
    'telemetry'
)

# Copy global files: auth → data
foreach ($f in $globalFiles) {
    $src = Join-Path $authRoot $f
    $dst = Join-Path $dataRoot $f
    if (Test-Path $src) {
        try { Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop } catch { }
    }
}

# Copy global dirs: auth → data (recursive merge; doesn't blow away project-side additions)
foreach ($d in $globalDirs) {
    $src = Join-Path $authRoot $d
    $dst = Join-Path $dataRoot $d
    if (-not (Test-Path $src)) {
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        continue
    }
    if (-not (Test-Path $dst)) {
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
    }
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
}

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
#   CWC_ALLOW_NETS=cidr,cidr,…  re-allow specific subnets (e.g. "192.168.50.0/24")
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

# Extra hosts (FQDN -> IP / host-gateway).
# CWC_EXTRA_HOSTS=fqdn:target,fqdn:target — written by the launcher from `cwc firewall
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

    $added = @()
    $skipped = @()
    $pokedIPs = @{}
    foreach ($pair in $env:CWC_EXTRA_HOSTS.Split(',')) {
        $pair = $pair.Trim()
        if (-not $pair) { continue }
        $parts = $pair.Split(':', 2)
        if ($parts.Count -lt 2) { continue }
        $fqdn = $parts[0].Trim()
        $target = $parts[1].Trim()
        if ($target -eq 'host-gateway') {
            if (-not $gatewayIp) {
                $skipped += "$fqdn (host-gateway unresolvable)"
                continue
            }
            $target = $gatewayIp
        }
        # Idempotent: skip if FQDN already mapped in hosts file
        $existing = Select-String -Path $hostsFile -Pattern "^\s*\S+\s+$([regex]::Escape($fqdn))\s*$" -ErrorAction SilentlyContinue
        if (-not $existing) {
            Add-Content -LiteralPath $hostsFile -Value "$target`t$fqdn"
        }
        $added += "$fqdn -> $target"

        # Poke a /32 hole through the lockdown if the target is in an RFC1918 range.
        # Otherwise the FQDN resolves but the route is blackholed.
        $isPrivate = $target -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)'
        if ($isPrivate -and $hostIdx -and $hostDefaultGw -and -not $pokedIPs.ContainsKey($target)) {
            try {
                New-NetRoute -DestinationPrefix "$target/32" -InterfaceIndex $hostIdx -NextHop $hostDefaultGw -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                $pokedIPs[$target] = $true
            } catch { }
        }
    }
    if ($added.Count -gt 0) {
        $note = if ($pokedIPs.Count -gt 0) { " (allowed: $($pokedIPs.Keys -join ', '))" } else { '' }
        Write-Host "[cwc] hosts: $($added -join ', ')$note"
    }
    if ($skipped.Count -gt 0) {
        Write-Host "[cwc] hosts skipped: $($skipped -join ', ')"
    }
}

# Hand off to the CMD (claude, powershell, etc.)
# A subtle PowerShell gotcha here: PowerShell unwraps single-element arrays when an
# `if`-expression's value is assigned to a variable. So `$rest = if(...) { @($x) }` becomes
# a scalar string when there's exactly one trailing arg — `@$rest` then splats character-by-
# character (so `--version` becomes `-`, `-`, `v`, `e`, …). Splitting the assignment per
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

# On exit: copy globals back to the auth mount so other projects pick up changes
# (auth tokens refreshed, settings.json edited, plugins installed, etc.).
foreach ($f in $globalFiles) {
    $src = Join-Path $dataRoot $f
    $dst = Join-Path $authRoot $f
    if (Test-Path $src) {
        try { Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop } catch { }
    }
}
foreach ($d in $globalDirs) {
    $src = Join-Path $dataRoot $d
    $dst = Join-Path $authRoot $d
    if (Test-Path $src) {
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Force -Path $dst | Out-Null }
        Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
