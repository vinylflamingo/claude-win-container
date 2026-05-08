# Security model

This document describes what `cwc` defends against, what it deliberately doesn't, and the limitations you should know about before relying on it.

It's deliberately direct about what's a "speed-bump" vs. real isolation. If you're using `cwc` for personal dev work, the speed-bumps are usually enough; if you're handing the agent rights you wouldn't hand to an unknown human, read each layer's "Limitations" subsection and the [Future work](#future-work-host-side-enforcement) section before deciding.

## Threat model

The threat we're defending against is **the agent reaching resources the developer didn't authorize**.

Not in scope:
- The developer intentionally giving the agent broad access (mounting `C:\` rw, disabling the firewall, allowing any FQDN). That's the developer's call. cwc starts at restrictive defaults; relaxing them is your decision.
- The agent doing harm to things the developer *did* authorize. If you give the agent write access to your project, it can rewrite your project. That's by design.
- Sophisticated supply-chain attacks (compromised npm packages, GitHub repos). Public egress is allowed; package code from npm runs in the container. Nothing in cwc filters which packages claude or its MCP servers fetch.

In scope:
- An agent acting on a wrong instruction or a prompt injection silently expanding what it can reach (LAN, host filesystem, persistent state of other projects).
- Workspace files driving silent policy changes — e.g., the agent writing `.env` to disable the lockdown, or planting `claude-sandbox.overlay.yml` to mount the host C drive.
- Cross-project contamination — an agent in project A persisting code/config that runs in project B's session.
- Credential exfiltration via DNS spoofing of `api.anthropic.com`.

## Defense layers

cwc has five layers. They stack.

### 1. Filesystem isolation (Docker bind mounts)

The container sees:
- `C:\workspace` — your project, RW.
- `C:\claude-data` — per-project state (memory, sessions, plugins, settings overlay).
- `C:\command-history` — per-project shell history.
- `C:\claude-auth` — shared auth state (OAuth tokens, MCP-auth cache, global settings).
- `C:\docs\<name>` — any folders you added with `cwc mount add`.

Your home folder, the rest of the host filesystem, the Docker socket, and host devices are not visible inside the container. Hyper-V isolation (default on Windows 10/11 Pro+) gives kernel separation: even a compromised container can't reach the host kernel.

**Limitations.** A project shipping `claude-sandbox.overlay.yml` can extend the mount set. Layer 4 (the trust system) catches that — you have to explicitly trust the overlay before it's loaded.

### 2. LAN-egress lockdown (in-container, default on)

The entrypoint installs blackhole routes for RFC1918, IPv6 link-local, and IPv6 ULA destinations. Outbound TCP to `192.168.x.x` / `10.x.x.x` / `172.16.x.x` / `169.254.x.x` / `fe80::/10` / `fc00::/7` is dropped. Public IPs (Anthropic, npm, GitHub, etc.) route normally.

You can re-allow specific subnets with `cwc firewall allow <cidr>`, and map FQDNs to host services with `cwc firewall host-add`. See [`firewall.md`](./firewall.md) for the mechanics and per-port narrowing.

**Limitations.** This is enforced *inside* the container. The agent has admin rights inside the container and can run `Remove-NetRoute` to disable the blackhole. Layer 5 (harden) raises that bar; full closure requires host-side enforcement which is documented as future work below.

### 3. Per-port host-service narrowing (`cwc firewall host-add`)

When you run `cwc firewall host-add traefik.local host-gateway 443`, the entrypoint:
- Allocates a per-FQDN loopback IP (`127.0.0.X`).
- Sets up `netsh interface portproxy` to forward `127.0.0.X:443 → <host-gateway>:443`.
- Writes `127.0.0.X traefik.local` into the container's hosts file.

Result: the agent reaching `traefik.local:443` works; `traefik.local:8080` doesn't (no portproxy listener on that port for the loopback IP).

**Limitations.** A `/32` allow-route through the lockdown is necessary for portproxy itself to reach the gateway IP. That allow-route is necessarily all-ports (Windows routing has no per-port granularity). So if the agent discovers the gateway IP (e.g. via `Resolve-DnsName host.docker.internal`) and connects to it directly on a different port, it succeeds. The narrowing covers the FQDN path; direct-IP-to-gateway is a known gap, addressable only by host-side enforcement.

### 4. Workspace file trust (`cwc trust`)

Three files in your project drive what flows into the next session:
- `claude-sandbox.overlay.yml` — auto-loaded compose overlay (mounts, networks, etc.).
- `.env` — environment variables forwarded into the container.
- `.mcp.json` — MCP server registrations + extra `${KEY}` references that get forwarded from your shell env.

The agent has RW on the workspace, so it can edit any of these. cwc tracks a per-project SHA-256 of each tracked file in `~/.cwc/config.json`. Before launch, if any file's hash doesn't match (or it's an untrusted file that newly appeared), cwc refuses to start until you run `cwc trust`.

In an interactive session, you get a prompt with a per-file diff summary. In a non-interactive session (CI, etc.), cwc fails fast with a "run `cwc trust`" message — no silent inheritance.

**`CWC_*` env vars are *never* read from project `.env`.** They're sandbox control flags; the agent could trivially bypass the lockdown by writing `CWC_LOCKDOWN_LAN=0` to `.env` if we honored that. Persistent CWC_* settings live in `~/.cwc/config.json`; one-shot overrides go through your shell env.

**Limitations.** If you `cwc trust` without reading the diff, you lose this protection. The prompt is a guard rail, not a wall.

### 5. Tamper-resistant harden (`cwc harden enable`, opt-in)

The default lockdown is in-container, so admin in the container can disable it. Harden adds an in-container watchdog process that runs every 2 seconds and:
- Re-applies blackhole routes if any are removed.
- Removes unauthorized `/32` allow-routes to RFC1918 destinations (anything beyond what cwc set up itself).
- Restores the hosts file from snapshot if its contents change.
- Logs new entries in the trust store (does not auto-revert — could break legitimate corporate-CA setups).

**Limitations.** Harden is also in-container. The agent can:
- `Stop-Process` the watchdog.
- `Remove-Item` the watchdog script.
- Race the loop: change a route, make an outbound TCP connection (which persists once established), and accept the route being reverted 2s later.

Each of these is a deliberate, multi-step act. The realistic threat (claude tool-using its way to a `Remove-NetRoute` because something seemed in the way) is closed; a determined attacker is not.

For real isolation, the answer is host-side enforcement — see [Future work](#future-work-host-side-enforcement).

## `cwc dev` and the threat model

`cwc dev` runs against a local `:dev` image built from the Dockerfile next to `cwc.ps1`. It's a developer-iteration tool, not a hardened path — the threat model assumes a **trusted dev environment**:

- **Requires a clone.** Dev mode refuses without a Dockerfile next to the launcher. The published install (`~/.cwc/`) drops only the launcher files, so end-user installs can't enter dev mode by accident.
- **Session-scoped.** Each `cwc dev` invocation explicitly opts in. There's no persistent "always-dev" toggle that could survive a reboot or shell restart unnoticed.
- **Host-side flag store.** `~/.cwc/dev.json` lives outside the workspace, like the other cwc config files. The agent in the container can't see or modify it.

### `live_entrypoint_mount` flag

When the `live_entrypoint_mount` dev flag is on, `cwc dev` bind-mounts the clone's `entrypoint.ps1` over `C:\entrypoint.ps1` inside the container, **read-only**. This lets you iterate on entrypoint behavior without rebuilding the image — the new file takes effect on next launch.

**Threat-model implications:**

- The mounted file is read-only inside the container — the agent can't modify it during a session.
- The host source is the clone's `entrypoint.ps1`, which sits in the developer's working tree. If the agent (or anything else) modifies the host file between `cwc dev` invocations, the next launch picks up the modified version. **The trust system protects workspace files inside the project; it does NOT cover files in the cwc clone itself.**
- The clone is *not* mounted as a workspace. The agent only sees the project workspace (as usual) plus the bind-mounted entrypoint file at the container's system path. There's no path from a session to "edit my own entrypoint and persist it."
- This flag is therefore safe to leave on during routine dev work, but if you're using `cwc dev` to *test* whether the baked-in image is correct, turn it off so you're testing the actual image.

The flag is off by default. Turning it on is an explicit `cwc dev flag set live_entrypoint_mount on` — banner text on every dev session shows when it's active so you can't forget.

## Cross-project state

### Sandbox config split: global vs per-project

Sandbox configuration is split across two files to balance "user can never accidentally weaken security policy" against "every project gets only the access it needs":

| File | Scope | Holds |
| --- | --- | --- |
| `~/.cwc/config.json` | **Global** | `host_denylist` (FQDNs `cwc firewall host-add` refuses), `defaults` block (system-wide defaults applied when a project doesn't override). |
| `~/.cwc/projects/<slug>/config.json` | **Per-project** | `lockdown_lan`, `harden_enabled`, `allow_nets`, `extra_hosts`, `mounts`, `trusted_files`. `<slug>` = SHA-1 of the project's absolute path, basename-prefixed (12 hex chars). |

**Why this matters for the threat model.** Both files live outside the workspace (under `~/.cwc/`, which is *not* bind-mounted into the container). The agent has no path to read or modify them. So per-project config doesn't change the agent threat model — it just narrows what each project's sandbox does, so an unrelated project's allowed CIDRs / open host ports / mounted folders aren't leaked into this session.

**Why the denylist stays global.** The denylist is what stops any project from mapping `*.anthropic.com` to a hosts-file injection target. If it were per-project, a misconfigured project (or a user accidentally running `denylist remove` once) would leave one project unprotected. Global means the protection is uniform.

Per-project config is created by `cwc setup`. The first time you run `cwc` in a project that has no config, the wizard auto-triggers (interactive sessions only). Re-run `cwc setup` to reconfigure.

### Per-project state directories

`~/.claude-win-container/auth/` is shared across all projects' sessions. It holds:
- `.credentials.json` — OAuth tokens. Needed across projects so you don't re-auth on each `cd`.
- `mcp-needs-auth-cache.json` — small cache, regenerable.
- `settings.json` — global preferences (theme, telemetry, autoUpdater).

`~/.claude-win-container/projects/<slug>/` is per-project. Holds:
- `config/` — Claude's per-project state (sessions, todos, plans, history.jsonl, plugins, caches, statsig, telemetry).
- `config/settings-project.json` — per-project settings overlay (computed delta vs. global on each session exit).
- `history/` — shell history.

**`settings.json` deep-merge.** At session entry, the entrypoint reads global `settings.json` and the per-project overlay, deep-merges them (project wins on conflict), and writes the merged result to `C:\claude-data\settings.json` (where Claude reads). At session exit, the entrypoint reads back what Claude has now, computes the delta vs. the global baseline, and writes that delta to the per-project overlay. **Global is never mutated by sessions.** This is what closes the cross-project agent-persistence path: an MCP server installed by an agent in project A lands in project A's overlay, not in global, so project B's sessions don't see it.

`cwc auth reset` wipes the shared auth dir cleanly when you want to start fresh.

## Adversarial validation: the CTF suite

The integration suite (`tests/run.ps1`) verifies that the defense layers above are wired correctly — that the firewall blocks what it claims to, that bind mounts expose only what they should. That catches what we knew to test for.

The CTF suite (`tests/ctf/`) is the complement: it spawns Claude Code as an adversarial agent told to break out of the sandbox and capture planted flags. A leak there is a real shipping bug — the suite tests the same defaults a user gets, not a hardened CI-only config. Architecture and design is in [`ctf-suite.md`](./ctf-suite.md); operational reference is in [`tests/ctf/README.md`](../tests/ctf/README.md).

Currently the suite ships one scenario (`host-file-exfil`, exercising defense layer 1's bind-mount boundary). LAN-blocked and external-deny scenarios are planned next.

## Future work: host-side enforcement

The strongest defense against agent-with-admin would be enforcement on the host, outside the container's reach. We investigated five paths through a series of empirical spikes (preserved in [`tests/spikes/`](../tests/spikes/)). The full investigation outcome and the recommended alternatives for users who need stronger isolation are written up in [`host-side-enforcement.md`](./host-side-enforcement.md). Headline result:

| Path | Result | Why |
| --- | --- | --- |
| Hyper-V Firewall (Win 11 22H2+) | Doesn't see Docker | Docker Desktop's Windows containers don't register a VM creator |
| Hyper-V VM extended ACLs | Doesn't see Docker | `Get-VM` doesn't enumerate HCS-managed containers |
| Windows Defender Firewall on the NAT bridge | Doesn't see container egress | VFP intercepts traffic below the WFP firewall layer |
| HNS endpoint policy POST | **Metadata-only, no enforcement** | API accepts the ACL onto the endpoint object; VFP does not reload |
| HCN `HcnModifyEndpoint` (P/Invoke) | **Metadata-only, no enforcement** | Same outcome on Docker-created endpoints; the modern API doesn't reconcile either |
| `vfpctrl` direct | **Per-port commands rejected** | `vfpctrl /list-vmswitch-port` works but no per-port modifier ordering accepts `/get-port-state` |

The investigation closed NO-GO on Win 11 Pro N build 26200 + Docker Desktop 28.2.2. v1 ships harden as a stronger in-container speed-bump and the v2 host-side-enforcement plan is shelved indefinitely; see the [investigation outcome](./host-side-enforcement.md) for the empirical detail and what would change the result.

If you need real isolation today, the recommended alternatives (with concrete setup outlines in [`host-side-enforcement.md`](./host-side-enforcement.md)) are:

- A host-side outbound HTTPS proxy with FQDN allowlist (`mitmproxy`). Forces all egress through a host-controlled choke point. Complicates setup; requires CA in the container's trust store.
- A separate Windows VM running Docker Desktop, network-isolated at the hypervisor level. Real isolation, biggest setup cost.

## Quick reference

| Capability | Command |
| --- | --- |
| Toggle LAN lockdown | `cwc firewall enable` / `disable` |
| Allow a subnet | `cwc firewall allow <cidr>` |
| Map FQDN to host | `cwc firewall host-add <fqdn> [target] [ports]` |
| Manage host-add denylist | `cwc firewall denylist {list,add,remove,reset}` |
| Trust workspace files | `cwc trust` |
| List trust state | `cwc trust list` |
| Untrust this project | `cwc untrust` |
| Reset shared auth | `cwc auth reset` |
| Toggle harden | `cwc harden {enable,disable,status}` |

## Reporting

If you find a way to escape any of the above without admin in the container, please open an issue at <https://github.com/vinylflamingo/claude-win-container/issues>.
