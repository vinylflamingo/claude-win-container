# claude-win-container — Implementation Plan

A reusable, project-agnostic Windows container for running Claude Code in a sandbox.
The current Sitecore-coupled implementation in `sitecorecms/` is the reference; this
project extracts the generic infrastructure so any codebase on this machine can launch
a Claude session with one command.

---

## 1. Goals & non-goals

**Goals**
- One image, one launcher, used from any project directory on the host.
- Per-project Claude state (auth, memory, history) is isolated — switching directories
  doesn't cross-contaminate sessions.
- Egress is restricted to an explicit allowlist; the container can't freely call out.
- Project repos stay clean: at most they ship a `.mcp.json`, a `CLAUDE.md`, and
  optionally a tiny project-specific overlay file.
- Launcher is invoked from the *project directory* (`cd C:\path\to\project; cwc`),
  never from this repo.

**Non-goals**
- Joining the project's docker-compose network. Reach Sitecore (or any backend) over
  normal HTTPS using its FQDN. If a project later needs in-network access, it can ship
  its own overlay file (see §6) — the base setup doesn't bake in network plumbing.
- Linux containers. Windows-host + Windows-container only. Cross-platform isn't free
  and isn't needed.
- Bundling MCP servers. Each project declares its own MCP servers in `.mcp.json`; the
  container only needs the *runtimes* (Node, optionally Python) to execute them.

---

## 2. Reference: what exists today in `sitecorecms/`

For context — what we're extracting from:

| File | Role | Generic? | Action |
| --- | --- | --- | --- |
| `docker/build/claude/Dockerfile` | Image: Win base + Node + Claude Code | Yes | **Move** |
| `docker/build/claude/entrypoint.ps1` | Container entrypoint | Yes | **Move** |
| `docker-compose.claude.yml` | Service definition | Mostly | **Adapt** |
| `docker-compose.claude.sitecore.yml` | Local-Sitecore network overlay | Sitecore-specific | **Leave in sitecorecms** as the model for per-project overlays |
| `docker-compose.claude.local.yml.example` | Per-dev mounts overlay | Mostly generic pattern | **Re-template** in this repo |
| `claude.ps1` | Launcher | Sitecore-coupled | **Rewrite** as `cwc.ps1` (project-agnostic) |
| `.env.claude.example` | (already deleted) | — | n/a |
| `.gitignore` Claude block | State + overlay ignores | Yes | **Document** for project repos |
| `docker/data/claude/` | Persistent state bind | Yes — but location changes | **Move to per-user, per-project location** (see §5) |

---

## 3. Repo layout

```
claude-win-container/
├── README.md                              # quickstart
├── IMPLEMENTATION_PLAN.md                 # (this file)
├── Dockerfile                             # Windows base + Node + Claude Code
├── entrypoint.ps1                         # container entrypoint
├── docker-compose.yml                     # service definition (no project-specific bits)
├── cwc.ps1                                # the launcher — symlinked or PATH-added
├── overlays/
│   └── project-overlay.example.yml        # template projects can copy + adapt
└── docs/
    ├── per-project-setup.md               # what a project repo needs (.mcp.json, etc.)
    └── firewall.md                        # LAN-egress lockdown mechanics + overrides
```

---

## 4. Architecture

### 4.1 Image (`Dockerfile`)
- Base: `mcr.microsoft.com/windows/servercore:ltsc2019` (configurable via build arg).
- Installs: Node (build-arg version), `@anthropic-ai/claude-code` (latest by default,
  pinnable via build arg).
- No project-specific tools. If a project needs extra runtimes (Python, .NET SDK), it
  installs them via its own MCP servers or the launcher exposes a `--extra-tools` flag.
- Sets `CLAUDE_CONFIG_DIR=C:\claude-data` and `DISABLE_AUTOUPDATER=1` (we control versions
  via image rebuild, not in-place upgrades).

### 4.2 Launcher (`cwc.ps1`)
A PowerShell script the user invokes from any project directory. Behavior:

1. **Validate**: confirms `docker` is reachable, image is built (offers to build if not),
   and `$PWD` looks like a project root (heuristic: contains `.git`, `package.json`,
   `*.sln`, or `.mcp.json`; user can `--force` to override).
2. **Resolve state directory**: computes a stable per-project state path (see §5) and
   creates it if missing.
3. **Discover overlays**:
   - Always loads `<this-repo>/docker-compose.yml`.
   - If `$PWD/claude-sandbox.overlay.yml` exists, layers it (project-specific tweaks:
     extra mounts, network attach, extra_hosts).
4. **Forward env**: if `$PWD/.env` exists, parses it and forwards a curated allowlist
   of keys into the container (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, plus any
   key prefixed `CLAUDE_*` or matching the project's `.mcp.json` references). It does
   *not* slurp the entire `.env` — see §5 on auth and §7 on env handling.
5. **Mounts**:
   - `$PWD` → `C:\workspace` (read-write)
   - `<state-dir>/config` → `C:\claude-data`
   - `<state-dir>/history` → `C:\command-history`
6. **Run**: `docker compose run --rm claude-code <cmd>`. Default cmd is `claude`.
   Pass-through args support `cwc powershell`, `cwc -Build`, etc.

### 4.3 Compose file (`docker-compose.yml`)
- Single `claude-code` service. No external networks, no `extra_hosts`. Default bridge
  networking — relies on host DNS for FQDN resolution.
- Explicit `environment:` block listing only the keys the launcher will set (no
  `env_file:`). Launcher passes values via `-e` flags or composed environment.
- Build args + runtime limits parameterized via env vars the launcher sets.

---

## 5. State management

The trickiest design call. Three constraints to satisfy simultaneously:

1. **Auth persists across projects** — re-authing every time you `cd` is unacceptable.
2. **Memory is per-project** — Claude's `MEMORY.md` and project notes shouldn't leak
   between repos.
3. **Workspace mount path is constant** (`C:\workspace`) so `.mcp.json` and absolute
   paths inside the container are predictable.

**Decision: split state into two scopes.**

```
%USERPROFILE%\.claude-win-container\
├── auth\                                  # global — OAuth tokens, API key cache
│   └── (Claude's auth-only files)
└── projects\
    └── <slugified-project-path>\
        ├── config\                        # per-project Claude config (memory, sessions, settings)
        └── history\                       # per-project shell history
```

Inside the container:
- `C:\claude-data\` ← bind-mounted from `auth/` (global) AND `projects/<slug>/config/`
  (project). Implementation: mount the per-project dir as `C:\claude-data\` and then
  symlink/junction the auth-relevant subpaths from the global dir at container startup
  (handled in `entrypoint.ps1`).

**Slug derivation:** SHA-1 hash of the absolute project path, first 12 chars, prefixed
with the basename (e.g., `sitecorecms-a3f9c1d4e2b8`). Stable across runs, collision-safe.

**Tradeoff acknowledged:** the symlink-into-bind-mount dance is fiddly. Simpler
alternative: make ALL state per-project, accept that auth must be re-entered when first
cd-ing into a new project (or copy auth files manually). Decide during implementation
once we see how Claude Code's config directory actually partitions auth vs memory.

---

## 6. Per-project integration

What a project repo needs to add to opt in:

**Required:**
- A `.mcp.json` declaring the MCP servers it wants. (No change from today.)
- Entries in `.gitignore`:
  ```
  claude-sandbox.overlay.yml      # if used
  ```

**Optional:**
- `claude-sandbox.overlay.yml` — a tiny compose overlay if the project needs extras the
  base doesn't provide. The Sitecore example would be ~20 lines:
  ```yaml
  services:
    claude-code:
      extra_hosts:
        - "${CM_HOST}:host-gateway"
      networks: [sitecore]
  networks:
    sitecore:
      name: ${COMPOSE_PROJECT_NAME:-ion}_default
      external: true
  ```
  (User has signaled this is **not** needed for the Sitecore project — they'll call CM
  over normal HTTPS — so the overlay mechanism is forward-looking, not required for v1.)
- A `.env` containing values the launcher should forward (see §4.2 step 4).

**Documentation to ship in this repo:** `docs/per-project-setup.md` with a copy-paste
section.

---

## 7. Egress allowlist (firewall posture)

Default-deny outbound, allow only what's needed. Approach options, ranked by complexity:

**Option A — Windows Firewall rules inside the container (simplest, least bulletproof).**
Set in Dockerfile via `New-NetFirewallRule`. Limitation: a process with admin in the
container can disable them. Acceptable for a "good faith" sandbox, not for hostile-code
isolation.

**Option B — Dedicated Docker network with restrictive egress, enforced at the host.**
Create a custom NAT network with no internet routing, then explicitly punch holes for
the allowlist via host firewall + DNS rewriting. More robust, much more setup.

**Option C — Outbound HTTP proxy (mitmproxy or squid) on the host, container forced
through it via env vars.** Most flexible (per-FQDN allowlist, TLS-aware), but needs a
proxy running on the host and TLS cert trusted in the container.

**Recommendation: start with Option A.** Document the allowlist clearly. Revisit once
real threat model is articulated.

> **Update from implementation:** Option A is **not viable** in Windows Server Core
> containers. The Windows Firewall service (`mpssvc`) ships stopped and disabled, and
> cannot be started inside the container — `New-NetFirewallRule` fails with `Windows
> Error 1753`. We pivoted to **routing-table blackholes** for RFC1918 + IPv6 ULA / link-local
> (the practical threat the user actually cared about: lateral movement to LAN). See
> `docs/firewall.md` for the mechanics. The original FQDN allowlist file was scrapped
> because (1) it was unenforced documentation only, (2) the contents were self-evident,
> (3) the actual security boundary is the routing-table lockdown which doesn't read it.

---

## 8. Implementation steps

Ordered build sequence. Each step should leave the system in a working state.

1. **Scaffold repo.** `git init`, `README.md` stub, `.gitignore`.
2. **Copy + de-Sitecore the Dockerfile.** Pull from `sitecorecms/docker/build/claude/`,
   strip any project-specific bits (there shouldn't be any, but verify).
3. **Author the base `docker-compose.yml`.** Generic, no networks/extra_hosts, explicit
   `environment:` block driven by launcher-supplied vars.
4. **Write `cwc.ps1` v1 — minimum viable.** Hard-codes per-project state under
   `%USERPROFILE%\.claude-win-container\projects\<slug>\`. No env forwarding yet; user
   can pass `-e KEY=VAL` flags. Verify it boots `claude` from any directory.
5. **Add env forwarding.** Parse `$PWD/.env`, forward only allowlisted keys. Document
   the allowlist; let projects extend via `claude-sandbox.overlay.yml`.
6. **Add overlay discovery.** Auto-include `$PWD/claude-sandbox.overlay.yml` when
   present. Test with a copy of the Sitecore overlay.
7. **Solve state split (§5).** Implement the auth-vs-project split via entrypoint
   symlinks, OR fall back to per-project-only if Claude's config layout doesn't make the
   split clean.
8. **Network egress controls.** ~~Option A — bake `New-NetFirewallRule` into Dockerfile~~
   not possible (see §7 update). Implemented routing-table blackholes for RFC1918 + IPv6
   ULA / link-local in `entrypoint.ps1`. User-tunable via `cwc firewall {allow|deny}` and
   per-FQDN host-mapping via `cwc firewall host-add`. See `docs/firewall.md`.
9. **Write `docs/per-project-setup.md`** — what a project repo needs to add.
10. **Migration of `sitecorecms/`** — see §9.
11. **PATH integration.** Document how to add `cwc.ps1` to PowerShell profile
    or `$env:Path` so it's invokable from anywhere as `cwc`.
12. **Smoke tests.** Launch from `sitecorecms/` (Sitecore work), launch from a fresh
    empty dir (sanity), launch from a non-Sitecore project to verify the abstraction
    holds.

---

## 9. Migration of `sitecorecms/` once this repo is ready

Things to **delete** from sitecorecms:
- `docker/build/claude/` (whole dir)
- `docker-compose.claude.yml`
- `docker-compose.claude.sitecore.yml`
- `docker-compose.claude.local.yml.example`
- `claude.ps1`
- `docker/data/claude/` (state moves to `%USERPROFILE%\.claude-win-container\projects\sitecorecms-<hash>\`)

Things to **keep** in sitecorecms:
- `.mcp.json` (already generic-ish — uses `${CM_HOST}` etc.)
- `.claude/` (project-specific Claude config)
- The `# ─── Claude Code sandbox ───` block in `.env` / `.env.example` — these are the
  values the launcher forwards. Keep them; just remove ones that were only needed by
  the old in-repo compose (`CLAUDE_BASE_IMAGE`, `CLAUDE_NODE_VERSION`, `CLAUDE_ISOLATION`,
  etc., which now live as build args in this repo).

Things to **update** in sitecorecms:
- `.gitignore` — remove the Claude block (no longer relevant).
- `README` (or wherever team onboarding lives) — point at this repo for sandbox setup.

User has confirmed the local Sitecore network attach is **not** needed — they'll call
CM over normal HTTPS — so no `claude-sandbox.overlay.yml` needed in sitecorecms.

---

## 10. Open questions

1. ~~**Auth split (§5):** does Claude Code's `CLAUDE_CONFIG_DIR` cleanly separate
   auth-only files from project files?~~ **Resolved.** Inspected real `~/.claude/`
   layout. Global: `.credentials.json`, `settings.json`, `plugins/`, `cache/`,
   `statsig/`, `telemetry/`, `mcp-needs-auth-cache.json`, `stats-cache.json`.
   Per-project: `projects/`, `sessions/`, `todos/`, `tasks/`, `plans/`,
   `history.jsonl`, `file-history/`, `session-env/`, `shell-snapshots/`. Junctioning
   the global dirs into the per-project dir was the original plan but **doesn't work**
   in Windows containers (reparse-point creation in bind mounts is denied), so the
   entrypoint copies in on entry and copies back on exit.
2. ~~**State location:**~~ **Resolved.** User confirmed `%USERPROFILE%\.claude-win-container\`.
3. **Image version policy:** rebuild on every Claude Code release? Pin per-launcher-version?
   Probably: rebuild quarterly + on-demand via `cwc -Build`. Still open — defer to
   real-world use to find the right cadence.
4. ~~**Multi-project concurrent sessions:**~~ **Resolved.** `docker compose run --rm`
   randomizes container names; concurrent sessions against different projects work
   out of the box (smoke-tested).
5. ~~**Egress allowlist for MCP server installs:**~~ **Moot.** Public-internet egress
   is not restricted in v1. The original FQDN allowlist file was removed because it
   was unenforced documentation. Threat model focused on LAN lateral movement instead;
   that's enforced via routing-table blackholes (see §7 update + `docs/firewall.md`).
