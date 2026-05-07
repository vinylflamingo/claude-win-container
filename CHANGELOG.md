# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is [Semantic Versioning](https://semver.org/).

## [Unreleased]

_Nothing yet. Open a feature branch off `main` and add entries here as you go._

## [0.1.1] - 2026-05-07

Major refactor of the per-project model + dev-mode tooling. Includes breaking changes to the config layout (no migration — re-run `cwc setup` per project) and to the install URL (now points at GitHub release assets instead of a branch). The image tag scheme is unchanged.

### Added

- **`cwc setup` subcommand** for per-project sandbox configuration. Walks 6 questions (LAN subnets, host services + ports + canonical `host` alias, custom FQDN→IP, folder mounts, harden) and writes `~/.cwc/projects/<slug>/config.json`. The first time you run `cwc` in a project, it auto-triggers this wizard inline (interactive sessions only) — non-interactive sessions fail closed with a "run `cwc setup` first" message. Re-run `cwc setup` anytime to reconfigure.
- **Canonical `host` hostname for host-machine services.** Q3 of the wizard now asks for a comma-separated TCP port list and always registers `host` → `host-gateway` with those ports. Inside the container, agents reach host services as `http://host:<port>`. Optional extra hostnames (e.g. `api.test`, `dev.local`) share the same port list.
- **`cwc dev` session-scoped dev mode.** Runs against a local `:dev` image (built from the Dockerfile next to `cwc.ps1`) for just that invocation; leaving puts you back in normal mode. Management subcommands: `cwc dev build`, `cwc dev rebuild` (no-cache), `cwc dev clean`, `cwc dev status`. Persistent flag store at `~/.cwc/dev.json`: `cwc dev flag {list|set|unset}`. The first flag, `live_entrypoint_mount`, bind-mounts the clone's `entrypoint.ps1` over `C:\entrypoint.ps1` inside the container — edits take effect on the next `cwc dev` with no rebuild. Requires running from a clone (Dockerfile must be next to cwc.ps1). Refuses host-side wrappers (`cwc dev firewall`, etc.) since they don't start a container.
- **Launch banner with version + freshness.** Every `cwc` launch now prints a one-line `[cwc] image: <tag> (<state>)` banner before the session summary. States: `latest stable` (`:latest` or matches GitHub's most recent release), `stable, latest`, `stable, outdated -- X.Y.Z is available`, `preview / pre-release`, `custom tag`. The freshness check hits `api.github.com/repos/.../releases/latest` and caches the result at `~/.cwc/version-cache.json` for 24h, so most launches don't make a network call. Set `CWC_SKIP_VERSION_CHECK=1` to disable the check (CI / offline). Dev sessions print their own `[cwc dev] running with ...` banner instead.
- **Project-isolation tests** (`tests/project-isolation.tests.ps1`) verify firewall allows, extra_hosts, and harden settings in project A do NOT leak into project B.
- **Dev tests** (`tests/dev.tests.ps1`) cover flag list/set/unset persistence, status output, host-side wrapping rejection.

### Changed

- **Per-project sandbox config (BREAKING).** Sandbox state is now split:
  - `~/.cwc/config.json` holds **only** global security policy: `host_denylist` and a `defaults` block.
  - `~/.cwc/projects/<slug>/config.json` holds everything else: `lockdown_lan`, `harden_enabled`, `allow_nets`, `extra_hosts`, `mounts`, `trusted_files`. `<slug>` is the existing project-slug formula (SHA-1 of absolute path, basename-prefixed, 12 hex chars), already used for `~/.claude-win-container/state/<slug>/`.

  All per-project subcommands (`cwc firewall {list, allow, deny, host-add, host-remove}`, `cwc mount`, `cwc harden`, `cwc trust`, `cwc untrust`) now read/write the per-project file. `cwc firewall denylist {list, add, remove, reset}` stays global. Outside a project root, per-project subcommands refuse with an actionable error. **This is a breaking change** — existing global configs from 0.1.0-alpha do NOT auto-migrate. Re-run `cwc setup` in each project. Trust state moves with each project (no longer slug-keyed in a global map).

- **Install wizard removed.** `install.ps1` is now a minimal one-shot: security primer → file download → `$PROFILE` alias. All firewall / mount / host-services configuration moved to `cwc setup`, which runs per-project. The `-SkipFirewallSetup` flag is gone (no firewall wizard at install time).
- **Install command moved to GitHub release assets.** The bootstrap URL is now `https://github.com/vinylflamingo/claude-win-container/releases/latest/download/install.ps1` (was `raw.githubusercontent.com/.../main/install.ps1`). `releases/latest` always redirects to the most recent stable release and skips `preview/*` prereleases, so new installs are decoupled from `main`'s state — no more "install fails because `main` is between releases." `install.ps1`, `cwc.ps1`, `docker-compose.yml`, and `project-overlay.example.yml` are now uploaded as release assets by the build workflow. **This is a breaking change** for anyone who scripted the old `raw.githubusercontent.com` URL; update bookmarks. Branch-ref installs (`-Ref main`, `-Ref release/x.y.z`) still work via the raw URL fallback for development.
- **`install.ps1` default `-Ref` changed from `main` to `latest`.** With `latest`, peer files are fetched from the same `releases/latest/download/` redirect. Tags (`-Ref v1.2.3`) pull from that release's assets. Branch refs continue to resolve through `raw.githubusercontent.com`.

## [0.1.0-alpha] - 2026-05-06

The initial public release. The project is in `alpha`: APIs (CLI shape, config schema, image tag layout) may still change before `0.1.0` proper. Use it, file issues, but don't pin production tooling to alpha tags.

### Added

- **Trust system** for workspace policy files. Tracks per-project SHA-256 of `claude-sandbox.overlay.yml`, `.env`, and `.mcp.json` in `~/.cwc/config.json`. Edits to these files (which can expand what flows into the next session) require explicit `cwc trust` ack — the agent can't silently widen the next session's sandbox by editing the workspace.
  - `cwc trust` — record current hashes for this project.
  - `cwc trust list` — show per-file status (`trusted` / `NEW` / `MODIFIED` / `DELETED` / `absent`).
  - `cwc untrust` — drop trust state; next launch re-prompts.
  - First launch in any project with at least one tracked file prompts interactively; non-interactive sessions fail closed with a "run `cwc trust`" message.
- **Hosts-file denylist** — `cwc firewall host-add` refuses FQDNs matching the denylist. Defaults cover Anthropic auth channels (`*.anthropic.com`, `*.claude.ai`, `*.claude.com`, `*.anthropic.ai`, plus bare-domain forms). Enforced at two layers: the launcher (config-write time) and the entrypoint (hosts-file-write time).
  - `cwc firewall denylist {list|add|remove|reset}`.
  - `remove` of a default entry prompts before unblocking.
- **Tamper-resistant in-container hardening** — opt-in. `cwc harden enable` turns on a watchdog that runs every 2 seconds inside the container:
  - Re-applies any removed blackhole routes.
  - Removes unauthorized `/32` allow-routes to RFC1918 destinations.
  - Restores the hosts file from a startup snapshot if its contents change.
  - Logs new entries in the local trust store (does not auto-revert).
  - Implementation uses PowerShell `Start-Job` with explicit `Import-Module NetTCPIP`/`NetAdapter`. Watchdog logs to `C:\cwc-watchdog\watchdog.log` inside the container.
  - `cwc harden {enable|disable|status}` — `status` documents what's enforced and the limitations.
- **Per-port host-add** — `cwc firewall host-add fqdn target ports` accepts a comma-separated port list (default `443,80`). Inside the container, each FQDN gets its own loopback IP (`127.0.0.X`) and `netsh portproxy` listeners on the listed ports. Ports not listed aren't bound and are unreachable via the FQDN.
- **`cwc auth` subcommand** for shared auth state management:
  - `cwc auth where` — print where shared and per-project state live.
  - `cwc auth reset` — wipe `~/.claude-win-container/auth/` (re-auth on next run; per-project state untouched).
- **FQDN / target validators** in `cwc firewall host-add` and the entrypoint's `CWC_EXTRA_HOSTS` parser. Refuses malformed FQDNs and non-IP non-`host-gateway` targets. Defense in depth — both the launcher and the entrypoint check.
- **`docs/security.md`** — full threat model, defense layers, cross-project state breakdown, future-work plan for host-side enforcement (with negative spike results documented).
- **Test infrastructure** — new test files (`denylist.tests.ps1`, `trust.tests.ps1`, `settings-merge.tests.ps1`, `harden.tests.ps1`). Harness extended with `Invoke-CwcOnHost` (host-side cwc invocation, captures all PowerShell streams via `*>&1`), `Should-NotEqual`, and config knobs for the new schema fields. `tests/run.ps1 -Build` rebuilds the image from the local Dockerfile before running — required when iterating on `entrypoint.ps1`.
- **Spike scripts** under `tests/spikes/` documenting the host-side enforcement investigation (Hyper-V Firewall, vNIC ACLs, Defender Firewall on the NAT bridge — all negative results given Docker Desktop's HCS-based architecture, which is why host-side enforcement is parked as future work).

### Changed

- **Auth bind narrowed.** Only `.credentials.json` and `mcp-needs-auth-cache.json` are whole-file global now. `settings.json` is **per-project** (deep-merged with a global baseline at session entry, delta-on-exit). `plugins/`, `cache/`, `statsig/`, `telemetry/` no longer sync — they live per-project. **This closes the cross-project agent-persistence vector**: an MCP server, hook, or plugin installed by an agent in project A no longer lands in project B's sessions.
  - On entry, the entrypoint reads `~/.claude-win-container/auth/settings.json` (global baseline) plus the per-project `settings-project.json` (overlay), deep-merges them with project values winning, and writes the merged result to `C:\claude-data\settings.json`.
  - On exit, the entrypoint diffs the final `settings.json` against the global baseline; the delta is written to `settings-project.json`. Global is never mutated by sessions.
- **`extra_hosts` config schema** changed from `{fqdn -> "<target-string>"}` to `{fqdn -> {target, ports}}`. Existing configs auto-migrate on first read with a one-time banner; default ports `443,80`.
- **`CWC_EXTRA_HOSTS` env-var format** changed from `fqdn:target,fqdn:target` to `fqdn|target|port,port;fqdn|target|ports`. The old colon-separated format is still accepted by the entrypoint as a fallback (defaults ports to `443,80`).
- **Installer wizard** expanded to six interactive questions (was four). New questions cover folder mounts and the harden offer. Security primer rewritten with explicit framing of agent capabilities and what cwc does/doesn't sandbox.
- **`cwc firewall list` output** now includes harden state and per-host port lists.
- **Container default for `iphlpsvc`** — entrypoint sets it to Manual + starts it before configuring `netsh portproxy`. Falls back to direct FQDN-to-IP hosts mapping (with a banner) if the service can't start, so functionality is preserved on any host.

### Notable non-features

(These sections describe deliberate design decisions during the initial development. Mostly relevant if you're auditing the security model — see [`docs/security.md`](./docs/security.md).)

- **`CWC_*` keys are not forwarded from a project's `.env`.** Sandbox flags (`CWC_LOCKDOWN_LAN`, `CWC_ALLOW_NETS`, `CWC_EXTRA_HOSTS`, `CWC_HARDEN`) read from your shell env (one-shot) or `~/.cwc/config.json` (persistent) only. The agent has RW access to the workspace, so allowing `.env` to drive sandbox flags would let it silently disable the lockdown / inject into the hosts file on the next session. Use `cwc firewall ...` / `cwc harden ...` for persistent settings; shell env for one-shot overrides.
- **`settings.json`, `plugins/`, `cache/`, `statsig/`, `telemetry/`, `stats-cache.json` are not whole-file global** in the auth bind. `settings.json` is deep-merged (per-project overlay vs. global baseline); the rest are per-project. This is what closes the cross-project agent-persistence vector — see **Changed** above.

### Security

- All of the above is the security delta. Highlights:
  - Closes the workspace-file self-bootstrap vector (trust system + `CWC_*` removal).
  - Closes the cross-project agent-persistence vector (auth bind narrowing).
  - Closes the API-key-MITM-via-hosts-injection vector (denylist).
  - Raises the bar against in-container tampering of the LAN lockdown (harden).
  - Narrows host-service exposure from "all ports on host vNIC" to "listed ports on host vNIC" via portproxy. (Direct-IP-to-gateway access on other ports is still possible — Windows routing has no per-port granularity. See `docs/security.md` for the limitation and host-side-enforcement future work.)

<!-- end -->

