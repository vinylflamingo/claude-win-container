# Firewall (LAN-egress lockdown)

The container can reach the public internet but is blocked from your private networks by default. This stops a runaway agent or MCP server from scanning your LAN, ssh'ing to internal hosts, or hitting things on `192.168.x.x` / `10.x.x.x` by accident.

## What's blocked

| Range | Notes |
| --- | --- |
| `10.0.0.0/8` | Private (Class A) |
| `172.16.0.0/12` | Private (Class B) — minus the container's own docker subnet, which stays reachable |
| `192.168.0.0/16` | Private (Class C) |
| `169.254.0.0/16` | Link-local — neighbour discovery, cloud metadata services |
| `fe80::/10` | IPv6 link-local |
| `fc00::/7` | IPv6 unique-local |

Loopback (`127.0.0.0/8`, `::1`), the container's own docker subnet, and the Docker host gateway are **not** blocked. Public IPs route normally through the gateway.

## How it works

`entrypoint.ps1` runs at every container start and adds blackhole routes (next-hop `0.0.0.0` / `::`) for the ranges above. Packets to those destinations have no resolvable layer-2 target on the container's vNIC, so the connection fails fast. The container's own subnet remains reachable because Windows routing picks the most-specific match — the broad `/12` blackhole loses to the more-specific `/20` route already in the table.

You'll see this banner on every session start when the lockdown is active:

```
[cwc] LAN egress: blocked 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, fe80::/10, fc00::/7
```

## Managing the lockdown — `cwc firewall`

The launcher edits a persistent user-wide config at `%USERPROFILE%\.cwc\config.json`. Settings apply on the next `cwc` session (no rebuild, no restart of anything).

```powershell
cwc firewall list                       # show current state and allow-list
cwc firewall allow 192.168.50.0/24      # re-allow a specific subnet
cwc firewall allow 10.5.0.0/16          # add as many as needed
cwc firewall deny 192.168.50.0/24       # remove from the allow-list
cwc firewall disable                    # turn the lockdown off entirely
cwc firewall enable                     # turn it back on (default)
```

When something is re-allowed, the startup banner shows it:

```
[cwc] LAN egress: blocked 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, fe80::/10, fc00::/7 (re-allowed 192.168.50.0/24)
```

When the lockdown is disabled, no banner is printed at all.

## Per-session / per-project overrides

If you don't want to touch the persistent config, set the env vars directly. They take precedence for that session only:

```powershell
# Just for this shell session
$env:CWC_LOCKDOWN_LAN = '0'
$env:CWC_ALLOW_NETS = '192.168.50.0/24,10.5.0.0/16'
cwc
```

```ini
# Or per-project, in .env (the launcher auto-forwards CWC_* keys)
CWC_LOCKDOWN_LAN=0
CWC_ALLOW_NETS=192.168.50.0/24
```

Precedence: project `.env` / shell env wins → falls back to `cwc firewall`-managed user config → falls back to defaults (lockdown on, no extra allow-list).

## Reaching services on the Docker host

The Docker host is reachable at the container's gateway (in the container's own subnet — not blocked). Use the standard `extra_hosts: host-gateway` pattern in a `claude-sandbox.overlay.yml`:

```yaml
services:
  claude-code:
    extra_hosts:
      - "cm.ion.localhost:host-gateway"
      - "internal-api.local:host-gateway"
```

This adds entries to the container's `hosts` file pointing those names at the Docker host's vNIC. If Traefik (or any proxy) listens on the host at `127.0.0.1:443`, the container reaches it via these names exactly like a browser on the host would.

You don't need to add `host-gateway` to the firewall allow-list — it's already in the container's own subnet.

> The container's own `127.0.0.1` is **the container's** loopback, not the host's. To reach the host, always go through `host-gateway` (typically via `extra_hosts`).

## Limitations

This is "speed-bump" defense, not isolation:

- Code running as Administrator inside the container can `Remove-NetRoute` the blackholes and re-enable LAN access. A determined attacker isn't stopped.
- The lockdown only restricts **outbound** traffic to private ranges. It doesn't filter by port or protocol — anything to a public IP, including SMB/SSH/RDP to public addresses, is allowed.
- Public IPs that happen to host hostile content aren't filtered. If you need per-FQDN egress controls, see the proxy option below.

If you need real isolation:

- **Host-side firewall on the Hyper-V vSwitch** — drop packets from the container's IP range to RFC1918 destinations at the host level. Survives in-container tampering.
- **Outbound HTTPS proxy** (mitmproxy / squid on the host) — per-FQDN allowlist, TLS-aware. Forces all egress through a host-controlled choke point.

## Verifying

Inside the container, after entrypoint runs:

```powershell
Test-NetConnection 192.168.1.1 -Port 80 -InformationLevel Quiet     # → False (LAN, blocked)
Test-NetConnection 1.1.1.1     -Port 443 -InformationLevel Quiet    # → True  (public, allowed)
Test-NetConnection 10.0.0.1    -Port 22 -InformationLevel Quiet     # → False (LAN, blocked)
```

Or just look at the startup banner.
