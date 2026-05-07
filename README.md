# claude-win-container

[![Build and release](https://github.com/vinylflamingo/claude-win-container/actions/workflows/build-and-release.yml/badge.svg)](https://github.com/vinylflamingo/claude-win-container/actions/workflows/build-and-release.yml)
[![Docker Hub](https://img.shields.io/docker/pulls/fcostoya/claude-win-container?label=docker%20pulls)](https://hub.docker.com/r/fcostoya/claude-win-container)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

A reusable Windows container for running [Claude Code](https://github.com/anthropics/claude-code) in a sandbox, with a layered defense model so the agent can't reach resources you didn't authorize. One image, one launcher, used from any project on the host.

## What you get

- **Filesystem isolation.** The agent sees your project (mounted at `C:\workspace`) and a per-project state directory. Your home folder, the Docker socket, and the rest of the host filesystem are not visible inside the container.
- **LAN-egress lockdown.** Public internet stays reachable (Anthropic, npm, GitHub); RFC1918 ranges and IPv6 link-local / ULA are blackholed at startup. Configurable per-host with `cwc firewall host-add`.
- **Per-port host narrowing.** When you map an FQDN to a host service, you list the ports the agent should reach — `cwc firewall host-add api.local host-gateway 443` opens only `443`, not the whole host vNIC.
- **Hosts-file denylist.** `cwc firewall host-add` refuses to map FQDNs that touch Anthropic's auth channels (`*.anthropic.com`, `*.claude.ai`, etc.), preventing hosts-file injection from being used to MITM the API key. Extendable.
- **Workspace-file trust.** `.env`, `.mcp.json`, and `claude-sandbox.overlay.yml` are tracked by SHA-256. Edits to these files (which can expand what flows into the next session) require explicit `cwc trust` ack — the agent can't silently widen its sandbox by editing the workspace.
- **Per-project state.** Plugins, sessions, hooks, permissions, and the MCP server registry all live per-project. An agent in project A can't plant code that runs in project B's session.
- **Optional hardening.** Opt-in `cwc harden` adds an in-container watchdog that re-applies the lockdown every 2s, restores the hosts file from snapshot if it changes, removes unauthorized RFC1918 routes, and logs new trust-store CAs.

It is **your decision** what the agent should and should not access. cwc starts at the most restrictive defaults; you relax them with `cwc firewall ...`, `cwc mount ...`, and `cwc harden ...` as your work requires.

Full security model + threat analysis: [`docs/security.md`](./docs/security.md).

## Quickstart

```powershell
irm https://github.com/vinylflamingo/claude-win-container/releases/latest/download/install.ps1 | iex
```

The installer is brief: a security primer (what an agent can do, what cwc sandboxes by default), then it drops the launcher into `%USERPROFILE%\.cwc\` and adds a `cwc` alias to your `$PROFILE`. Idempotent — safe to re-run.

Per-project sandbox configuration happens **inside each project** the first time you run `cwc` there:

```powershell
cd C:\Users\you\Projects\my-app
cwc                       # first run: triggers `cwc setup` automatically
                          # then pulls image (~6 GB) and launches `claude`
```

The first-run setup is a six-question wizard scoped to that project: LAN subnets, host-machine services + ports (always registers `host` so the agent reaches your dev server as `http://host:3000`), custom FQDN → IP mappings, folder mounts, and whether to enable `cwc harden`. Each project gets its own config at `%USERPROFILE%\.cwc\projects\<slug>\config.json` — host-side (the agent can't see or modify it). Re-run `cwc setup` anytime to reconfigure.

Subsequent runs of `cwc` in the same project skip the wizard and launch directly.

## Pre-requisites

- Windows 10 / 11 / Server 2019+ with **Docker Desktop in Windows-containers mode**.
- PowerShell 5.1+ (ships with Windows).
- Hyper-V isolation supported on the host (default on Windows 10/11 Pro+).

## Common workflows

```powershell
# Daily use
cwc                                    # run claude in this project
cwc -- --resume                        # forward args verbatim to claude
cwc powershell                         # drop into a container shell

# MCP servers
cwc mcp list                           # shorthand for `cwc claude mcp ...`
cwc mcp add github -- npx -y @modelcontextprotocol/server-github

# Network controls
cwc firewall list                      # current state (lockdown, allows, mappings, harden)
cwc firewall allow 192.168.50.0/24     # re-allow a specific LAN subnet
cwc firewall host-add api.local        # map a host service (default: 443,80)
cwc firewall host-add db.local host-gateway 5432   # explicit ports
cwc firewall denylist list             # FQDNs host-add will refuse

# Workspace policy
cwc trust                              # ack changes to .env / .mcp.json / overlay
cwc trust list                         # see what's tracked + current state
cwc untrust                            # force a fresh prompt next launch

# Tighter mode (opt-in)
cwc harden enable                      # turn on the tamper-resistant watchdog
cwc harden status                      # what it enforces, what it doesn't

# Auth state
cwc auth where                         # print where shared / per-project state lives
cwc auth reset                         # wipe shared auth — re-auth on next run

# Image lifecycle
cwc -Pull                              # pull the latest image
cwc -Build                             # build from local Dockerfile (requires repo clone)
```

Full command reference: [`docs/commands.md`](./docs/commands.md).

**MCP servers** are configured per-project via `.mcp.json` at the project root. Copy [`examples/mcp.example.json`](./examples/mcp.example.json) as a starting point, or use `cwc mcp add` to scaffold entries. Any `${KEY}` referenced in `.mcp.json` is auto-forwarded from your project's `.env`. See [`docs/per-project-setup.md`](./docs/per-project-setup.md) for the walkthrough.

## State and isolation

cwc keeps three kinds of state on your host:

| Path | Scope | Holds |
| --- | --- | --- |
| `~/.cwc/config.json` | machine-wide | firewall, denylist, mounts, trust hashes, harden setting |
| `~/.claude-win-container/auth/` | shared across projects | OAuth tokens, MCP-auth cache, global preferences (theme, telemetry) |
| `~/.claude-win-container/projects/<slug>/` | per-project | sessions, plugins, settings overlay, history |

Slug is `<basename>-<sha1[0..11]>` of the absolute project path — stable, collision-safe, deterministic.

Inside the container:

| Path | What |
| --- | --- |
| `C:\workspace` | your project (RW) |
| `C:\claude-data` | per-project state (`CLAUDE_CONFIG_DIR`) |
| `C:\command-history` | shell history (per-project) |
| `C:\claude-auth` | shared auth (specific files only persist back to host) |
| `C:\docs\<name>` | extra folders added with `cwc mount add` (read-only by default) |

Full layout + how the auth bind narrowing works: [`docs/security.md`](./docs/security.md).

## Pin a specific version

```powershell
$env:CWC_IMAGE = 'fcostoya/claude-win-container:0.1.1'
cwc
```

Or set it permanently in `$PROFILE` alongside the alias.

## Trying a preview release

`preview/*` branches publish unstable builds for testing. Each push produces SHA-pinned Docker tags (`:0.1.1.d9cd72`) preserved historically, plus a moving `:preview` Docker tag and a single GitHub release with the literal tag `preview` — both always point at the most recent preview build. Preview tags never become `:latest`; you opt in by name.

**See what's available**: <https://github.com/vinylflamingo/claude-win-container/releases> — the `preview` release at the top of the list is the most recent build; its name shows the version + commit SHA (e.g. `Preview 0.1.1.d9cd72`).

**Just the docker image — always latest preview** (keeps your installed `cwc.ps1` / `docker-compose.yml`):

```powershell
$env:CWC_IMAGE = 'fcostoya/claude-win-container:preview'
cwc
```

Unset to go back to the latest stable: `Remove-Item Env:CWC_IMAGE`.

**Just the docker image — pinned to a specific preview build** (when you want exactly one build, not whatever `:preview` currently points at):

```powershell
$env:CWC_IMAGE = 'fcostoya/claude-win-container:0.1.1.d9cd72'
cwc
```

The SHA-pinned tags stay around indefinitely on Docker Hub — useful for reproducing a specific QA result.

**Full install from the latest preview** (pulls the preview's `install.ps1`, `cwc.ps1`, `docker-compose.yml` instead of the latest stable's):

```powershell
& ([scriptblock]::Create((irm https://github.com/vinylflamingo/claude-win-container/releases/download/preview/install.ps1))) -Ref preview
```

`irm | iex` can't pass parameters to the downloaded script's `param()` block, so the install needs the `& ([scriptblock]::Create(...))` form to forward `-Ref preview` correctly. The installer records `channel: preview` in `~/.cwc/config.json`, and from then on `cwc` pulls `:preview` images by default until you reinstall from the stable channel. To go back, re-run the normal install command — it pulls from `releases/latest/download/`, which always resolves to the most recent **non-prerelease** release.

When the version under preview eventually ships as a stable release (same version number, e.g. `v0.1.1`), it gets a separate stable release entry and Docker tags (`:0.1.1`, `:latest`). The `preview` release stays around but stops being relevant for that version; the next preview push (for a future version) overwrites it.

## Working on cwc itself: `cwc dev`

If you've cloned the repo to make changes, `cwc dev` is the developer loop. Each invocation runs against a local `:dev` image (built from the Dockerfile next to `cwc.ps1`) for that one launch — leave the session and you're back in normal mode.

```powershell
cwc dev                       # launch claude in :dev container; builds image if missing
cwc dev powershell            # drop to a shell in the :dev container
cwc dev build                 # build :dev now
cwc dev rebuild               # remove :dev and build --no-cache
cwc dev status                # show :dev image presence + flag values
cwc dev flag list             # list dev-mode flags
```

One flag worth knowing: `cwc dev flag set live_entrypoint_mount on` bind-mounts the clone's `entrypoint.ps1` over `C:\entrypoint.ps1` inside the container, so edits take effect on the next `cwc dev` with no rebuild — turns ~5 minute build cycles into seconds when iterating on the entrypoint.

`cwc dev` requires running from a clone (Dockerfile must sit next to `cwc.ps1`); it errors out otherwise. Full guide in [`docs/development.md`](./docs/development.md).

## Building from source

```powershell
git clone https://github.com/vinylflamingo/claude-win-container
cd claude-win-container
docker compose build              # ~5-10 min for first build
& .\cwc.ps1 -Build                # rebuild + launch
```

The test suite (`tests\run.ps1`) is integration-grade — it spins up real containers and checks behaviour end-to-end. Pass `-Build` when iterating on `entrypoint.ps1` so tests run against your local image, not the published one.

## Uninstall

cwc keeps all of its state in three places. Uninstall is just removing those.

```powershell
# 1. Remove the cwc alias from your PowerShell profile.
#    install.ps1 added a marker line; this snippet removes the marker + the
#    Set-Alias line that followed it.
$marker  = '# claude-win-container alias (managed by install.ps1)'
$content = Get-Content -LiteralPath $PROFILE -Raw
$content = $content -replace ('(?ms)\r?\n?' + [regex]::Escape($marker) + '\r?\nSet-Alias cwc .+?\r?\n'), "`r`n"
Set-Content -LiteralPath $PROFILE -Value $content

# 2. Remove the launcher + per-project sandbox configs + dev/version caches.
Remove-Item -Recurse -Force "$env:USERPROFILE\.cwc"

# 3. Remove auth tokens + per-project Claude state (sessions, plugins, history).
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude-win-container"

# 4. Remove the docker images. Lists every cwc image tag you have locally
#    (latest, dev, preview, version-pinned) and removes them. The image is ~6 GB,
#    so you'll get the disk back.
docker images fcostoya/claude-win-container --format '{{.Repository}}:{{.Tag}}' |
    ForEach-Object { docker image rm $_ }
```

Open a new PowerShell session to drop the alias from the current shell, then verify: `Get-Command cwc -ErrorAction SilentlyContinue` should return nothing.

**Things this does NOT remove** (intentional):

- The Windows Server Core base image (`mcr.microsoft.com/windows/servercore:ltsc2019` or `:ltsc2022`). Other Windows containers on your machine likely share it — remove manually if you're sure nothing else needs it: `docker image rm mcr.microsoft.com/windows/servercore:ltsc2019`.
- Docker Desktop / Windows-containers mode itself.
- Anything an agent committed to your project workspaces. Those are *your* repos; cwc didn't put them there.

**Does harden change uninstall?** No. Harden is purely per-project (a boolean in `~/.cwc/projects/<slug>/config.json`) plus an in-container watchdog Job that exists only for the duration of a session. Nothing on your host outside `~/.cwc/`. Step 2 above wipes all of it.

## Troubleshooting

**"Refusing to launch — workspace files have changed."**
The trust system detected an edit to `.env`, `.mcp.json`, or `claude-sandbox.overlay.yml`. Run `cwc trust list` from the project to see what's flagged, then `cwc trust` to acknowledge.

**An MCP server inside the container can't reach a service on the host.**
Add it explicitly: `cwc firewall host-add <fqdn> host-gateway <port>`. The lockdown blocks the LAN by default; `host-add` sets up a per-FQDN portproxy so the agent reaches that service via the FQDN on the listed ports. See [`docs/firewall.md`](./docs/firewall.md).

**`cwc firewall host-add` refused my FQDN.**
The denylist (`cwc firewall denylist list`) covers Anthropic auth channels by default. If you genuinely need to override one, `cwc firewall denylist remove <pattern>` will prompt before unblocking a default. Adding new entries is `cwc firewall denylist add <pattern>`.

**`cwc harden` watchdog seems off.**
`cwc harden status` prints what's enforced and the limitations. Watchdog logs land at `C:\cwc-watchdog\watchdog.log` inside the container; surface them via `cwc powershell` then `Get-Content C:\cwc-watchdog\watchdog.log`.

**I want a clean slate.**
`cwc auth reset` wipes the shared auth dir (re-auth on next `cwc` run). Per-project state lives at `~/.claude-win-container/projects/<slug>/` — delete the slug directory to forget that project.

**The agent edited a config file in my workspace and it's now in `git status`.**
That's expected — `.env` / `.mcp.json` / overlays live in your repo. The trust system catches the change *before* it takes effect on the next session, so you can revert in your editor before running `cwc trust`.

## Releases

**Current version: `0.1.1`.** Still 0.x — APIs (CLI shape, config schema, image tag layout) may still change before 1.0. Don't pin production tooling to specific 0.x tags expecting compatibility across them.

Releases are branch-driven. Pushing a `release/<semver>` branch (e.g. `release/0.1.0`) triggers a CI run that publishes the following Docker tags:

- `fcostoya/claude-win-container:<version>-ltsc2019`
- `fcostoya/claude-win-container:<version>-ltsc2022`
- `fcostoya/claude-win-container:<version>` (= ltsc2019, max compat)
- `fcostoya/claude-win-container:latest` (= most-recent stable release, ltsc2019)
- `fcostoya/claude-win-container:latest-ltsc2019`
- `fcostoya/claude-win-container:latest-ltsc2022`

…and creates a GitHub release with a matching `v<version>` tag. `preview/<anything>` branches push the version-tagged images and create a GitHub *pre-release* but never touch `latest`. Full release process: [`docs/release.md`](./docs/release.md). See [Releases](https://github.com/vinylflamingo/claude-win-container/releases) for what's published.

## More

- [`docs/security.md`](./docs/security.md) — full threat model, defense layers, limitations, future work
- [`docs/commands.md`](./docs/commands.md) — every command and flag, with examples
- [`docs/firewall.md`](./docs/firewall.md) — LAN lockdown mechanics, host-add, denylist
- [`docs/per-project-setup.md`](./docs/per-project-setup.md) — what a project repo needs to opt in
- [`docs/release.md`](./docs/release.md) — release / CI process (maintainer-facing)
- [`CHANGELOG.md`](./CHANGELOG.md) — version history

## License

MIT — see [LICENSE](./LICENSE).
