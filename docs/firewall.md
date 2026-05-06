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

## Per-session overrides

If you don't want to touch the persistent config, set the env vars in your shell. They take precedence for that session only:

```powershell
# Just for this shell session
$env:CWC_LOCKDOWN_LAN = '0'
$env:CWC_ALLOW_NETS = '192.168.50.0/24,10.5.0.0/16'
cwc
```

`CWC_*` keys are deliberately **NOT** read from the project's `.env` any more. They control sandbox behaviour, and the agent has RW on the workspace — letting `.env` drive them would let the agent silently disable the lockdown on the next launch. Persistent settings go through `cwc firewall ...` (which writes `~/.cwc/config.json`); one-shot overrides go through shell env. See [`security.md`](./security.md) for the rationale.

Precedence: shell env wins → falls back to `cwc firewall`-managed user config → falls back to defaults.

## Reaching services on the Docker host

Use `cwc firewall host-add`. It maps an FQDN inside the container to a per-FQDN loopback IP and sets up `netsh portproxy` to forward listed TCP ports to the Docker host's vNIC.

```powershell
cwc firewall host-add traefik.local                       # default ports: 443,80
cwc firewall host-add traefik.local host-gateway 443      # 443 only
cwc firewall host-add db.local 192.168.1.5 5432           # explicit IP, port 5432
```

Inside the container, `traefik.local:443` is reachable; `traefik.local:8080` is not (no portproxy listener on that port). The denylist (`cwc firewall denylist list`) refuses host-add for FQDNs that touch Anthropic's auth channels.

**Caveat:** the underlying `host-gateway` IP is necessarily reachable on all ports through a `/32` allow-route (Windows routing has no per-port granularity). If the agent discovers the gateway IP (`Resolve-DnsName host.docker.internal`) and connects directly, it bypasses the FQDN-port narrowing. Closing this needs host-side enforcement — see [`security.md`](./security.md).

> The container's own `127.0.0.1` is **the container's** loopback, not the host's. The per-FQDN loopbacks (`127.0.0.2`, `127.0.0.3`, …) are also container-local; portproxy is what bridges them to the actual host gateway.

## Denylist for `host-add`

`cwc firewall host-add` refuses any FQDN that matches the denylist. Defaults cover Anthropic's auth-bearing channels — preventing the agent (or a careless `.env`) from redirecting `api.anthropic.com` via hosts-file injection and exfiltrating your OAuth token / API key on the next session.

Default entries (wildcard `*.` + bare-domain forms):

- `*.anthropic.com`, `anthropic.com`
- `*.claude.ai`, `claude.ai`
- `*.claude.com`, `claude.com`
- `*.anthropic.ai`, `anthropic.ai`

Manage via:

```powershell
cwc firewall denylist list                          # show defaults + customs (tagged)
cwc firewall denylist add internal.example.com     # extend the list
cwc firewall denylist remove *.example.com         # remove (prompts if it's a default)
cwc firewall denylist reset                        # clear customs, restore defaults
```

The denylist is enforced at **two layers** as defense-in-depth:

1. `cwc firewall host-add` checks at config-write time, refusing to persist a denylisted entry.
2. The container entrypoint checks again at hosts-file-write time, skipping any entry that matches — useful if `~/.cwc/config.json` was hand-edited or if `CWC_EXTRA_HOSTS` was set in the shell directly.

To add an FQDN to your own denylist that's not Anthropic-related (corporate auth, banking, anything you don't want the agent to be able to redirect), use `cwc firewall denylist add` and it'll be enforced the same way.

The denylist matches case-insensitively. `*.foo.com` matches `bar.foo.com` and `foo.com` but not `baz.bar.foo.com.evil.com` (suffix match against the *whole* domain after the leading `*.`).

## Limitations

This is "speed-bump" defense, not isolation:

- Code running as Administrator inside the container can `Remove-NetRoute` the blackholes and re-enable LAN access. `cwc harden enable` adds an in-container watchdog that re-applies them every 2s, raising the bar but not closing it.
- The lockdown only restricts **outbound** traffic to private ranges. It doesn't filter by port or protocol — anything to a public IP, including SMB/SSH/RDP to public addresses, is allowed.
- Public IPs that happen to host hostile content aren't filtered. If you need per-FQDN egress controls, an HTTPS-egress proxy is the right answer (not built into v1).

For real isolation, see [`security.md`](./security.md) — host-side enforcement is documented as future work; the practical alternatives today are an HTTPS-egress proxy on the host or a separate isolated VM.

## Verifying

Inside the container, after entrypoint runs:

```powershell
Test-NetConnection 192.168.1.1 -Port 80 -InformationLevel Quiet     # → False (LAN, blocked)
Test-NetConnection 1.1.1.1     -Port 443 -InformationLevel Quiet    # → True  (public, allowed)
Test-NetConnection 10.0.0.1    -Port 22 -InformationLevel Quiet     # → False (LAN, blocked)
```

Or just look at the startup banner.
