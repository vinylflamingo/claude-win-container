# Commands reference

Every command and flag supported by `cwc` and the installer, with a short description and a usage example.

## Install / update

### `install.ps1` (one-shot installer)

```powershell
irm https://github.com/vinylflamingo/claude-win-container/releases/latest/download/install.ps1 | iex
```

Downloads `cwc.ps1`, `docker-compose.yml`, and the overlay example into `%USERPROFILE%\.cwc\`, then adds a `cwc` alias to your PowerShell `$PROFILE`. Idempotent — re-running updates files in place. The installer no longer runs a configuration wizard; per-project sandbox config is collected by `cwc setup` (auto-triggered on first `cwc` in a new project).

The install URL is stable across releases — `releases/latest/download/<asset>` always redirects to the most recent stable GitHub release (preview/* releases are flagged as prereleases and skipped). Older versions used a `raw.githubusercontent.com/.../main/...` URL that pulled from the `main` branch directly; that's no longer required.

**Flags:**

| Flag | Default | Description |
| --- | --- | --- |
| `-Ref <ref>` | `latest` | What to install. `latest` = most-recent stable release. `preview` = most-recent preview build (single moving GitHub release with literal tag `preview`, updated on every preview push). A tag like `v1.2.3` = that exact stable release. A branch ref like `main` or `release/0.1.0` = raw files from that branch (dev / pre-release validation). |
| `-InstallDir <path>` | `%USERPROFILE%\.cwc` | Where to drop the launcher and config files. |
| `-LocalSource <path>` | (none) | Copy files from a local repo path instead of downloading from GitHub. Useful for development. |
| `-NoProfileEdit` | (off) | Skip writing the `cwc` alias to `$PROFILE`. |
| `-Test` | (off) | Run end-to-end in an isolated sandbox: redirects `USERPROFILE` to a temp dir, defaults `LocalSource` to the script's own directory, leaves `$PROFILE` alone, and cleans everything up on exit. No permanent changes. |

```powershell
# Pin to a specific stable release tag. Install.ps1 is also published as a
# release asset, so the bootstrap URL and -Ref both point at the same tag.
$args = @('-Ref','v1.2.3')
irm https://github.com/vinylflamingo/claude-win-container/releases/download/v1.2.3/install.ps1 | iex

# Install the latest preview build (moving GitHub release tagged `preview`).
$args = @('-Ref','preview')
irm https://github.com/vinylflamingo/claude-win-container/releases/download/preview/install.ps1 | iex

# Install from a branch (dev / pre-release validation -- raw.githubusercontent.com)
$args = @('-Ref','main')
irm https://raw.githubusercontent.com/vinylflamingo/claude-win-container/main/install.ps1 | iex

# Test the installer locally without touching your real config
.\install.ps1 -Test
```

---

## Top-level `cwc` commands

### `cwc`

```powershell
cwc
```

Runs `claude` inside the container against the current directory. First run pulls the image (`fcostoya/claude-win-container:latest`) from Docker Hub if it isn't local. Project-root heuristic must pass (directory must contain `.git`, `package.json`, `*.sln`, `.mcp.json`, `pyproject.toml`, `go.mod`, or `Cargo.toml` — bypass with `-Force`).

If the current project has no config (`~/.cwc/projects/<slug>/config.json`), `cwc` auto-triggers `cwc setup` inline before launching. Non-interactive sessions fail closed with a "run `cwc setup` first" message — the wizard requires a real terminal.

### `cwc setup`

```powershell
cwc setup
```

Per-project setup wizard. Walks 6 questions and writes `~/.cwc/projects/<slug>/config.json`:

1. (informational) Public internet — always allowed.
2. **LAN subnets** — CIDRs to re-allow through the lockdown.
3. **Host services** — comma-separated TCP ports to expose. The hostname `host` is always registered to point at the Docker host's vNIC, with the listed ports opened. The agent reaches services as `http://host:<port>`. Optional extra hostnames (e.g. `api.test`) share the same port list.
4. **Custom FQDN → IP** — explicit hostname-to-IP mappings (e.g. `legacy.box → 10.5.1.20`). RFC1918 addresses auto-add a containing `/24` to allow_nets.
5. **Folder mounts** — additional bind mounts at `C:\docs\<name>` (RO by default).
6. **Harden** — toggle the in-container watchdog for this project. Default ON.

The wizard requires an interactive session. `cwc setup` is also auto-triggered by `cwc` on first invocation in a project with no config. Re-run anytime to reconfigure (it offers to keep the existing config or replace it).

### `cwc dev [args...]`

```powershell
cwc dev                       # launch claude in the :dev image (build if missing)
cwc dev powershell            # drop to a shell in the :dev container
cwc dev mcp list              # any normal cwc command works under `dev`
```

**Session-scoped dev mode.** Runs against a local `:dev` image built from the Dockerfile next to `cwc.ps1`. Each `cwc dev` invocation explicitly opts in — leaving puts you back in normal mode. There's no persistent "I'm in dev now" toggle to forget about.

Falls through to the main launcher flow with `$env:CWC_IMAGE` rebound to `:dev`, so trust checks, the per-project setup wizard, env forwarding, mounts, and harden all still apply.

**Requires a clone.** `cwc dev` errors out if there's no Dockerfile next to `cwc.ps1` — the published install drops only the launcher files, so there's nothing to build from. Clone the repo and either set `Set-Alias cwc <clone>\cwc.ps1` for the session or rebind `$PROFILE`.

**Refuses host-side wrappers.** `cwc dev firewall list`, `cwc dev mount add`, etc. fail with "no `dev` wrapper needed" since those subcommands don't start a container. Use `cwc firewall list` directly.

```powershell
[cwc dev] running with fcostoya/claude-win-container:dev
```

is printed in magenta on every dev session so you always know which image you're hitting.

### `cwc dev build`

```powershell
cwc dev build
```

`docker compose build claude-code` against the `:dev` tag. First build is ~5–10 minutes; subsequent builds are layer-cached. Requires a clone.

### `cwc dev rebuild`

```powershell
cwc dev rebuild
```

Removes the `:dev` image then runs `docker compose build --no-cache claude-code`. Useful when the layer cache is stale or you suspect a build problem. Requires a clone.

### `cwc dev clean`

```powershell
cwc dev clean
```

`docker image rm` the `:dev` image. Idempotent — no-op if `:dev` isn't present. Doesn't touch `~/.cwc/dev.json` or your flag settings.

### `cwc dev status`

```powershell
cwc dev status
```

Prints:
- The `:dev` image tag the launcher uses (always `fcostoya/claude-win-container:dev`).
- Whether the image exists locally (and a hint to run `cwc dev build` if not).
- Whether the launcher is running from a clone, and the clone path.
- The current value of every dev flag, marked `(default)` or `(custom)`.

### `cwc dev flag {list|set|unset}`

```powershell
cwc dev flag list                                       # show all flags + values + defaults
cwc dev flag set live_entrypoint_mount on               # turn on
cwc dev flag set live_entrypoint_mount off              # turn off
cwc dev flag unset live_entrypoint_mount                # reset to default
```

Flag values persist at `~/.cwc/dev.json` and apply to every `cwc dev` session until you change them. The dev *mode* is session-scoped; only the flag *settings* persist.

`cwc dev flag set` accepts `on|off|true|false|1|0|yes|no|y|n` (case-insensitive) for the value.

**Available flags:**

| Flag | Default | Effect |
| --- | --- | --- |
| `live_entrypoint_mount` | `off` | Bind-mount the clone's `entrypoint.ps1` over `C:\entrypoint.ps1` inside the `:dev` container (read-only). Edits to `entrypoint.ps1` take effect on the next `cwc dev` with no rebuild — turns the entrypoint iteration loop from minutes to seconds. **Caveat:** flip off (or do a normal `cwc`) when you want to test the baked-in image behavior. |

Adding a new flag is a one-line entry in `$script:cwcDevFlagDefaults` in `cwc.ps1` plus per-flag application logic in the dev session block — see [`docs/development.md`](./development.md).

### `cwc <command> [args...]`

```powershell
cwc node --version
cwc git status
cwc <my-binary> arg1 arg2
```

Runs an arbitrary command inside the container instead of `claude`. The container has Node.js, Git, npm, npx, and PowerShell available out of the box.

### `cwc powershell`

```powershell
cwc powershell
```

Drops into an interactive PowerShell prompt inside the container. The project workspace is at `C:\workspace`. Useful for one-off inspection / `claude mcp` commands / debugging.

### `cwc mcp <subcommand> [args...]`

```powershell
cwc mcp list
cwc mcp add my-server -- npx -y @some/mcp-server
cwc mcp remove my-server
```

Shorthand for `cwc claude mcp ...`. The launcher detects `mcp` as the first positional arg and prepends `claude`. Reads/writes `.mcp.json` at the project root (which is bind-mounted, so changes persist on the host).

### `cwc help` / `cwc -Help` / `cwc -h`

```powershell
cwc help
cwc -h
```

Print the launcher's full usage. Doesn't touch Docker — runs in a few milliseconds.

### `cwc -- <args>`

```powershell
cwc -- --resume
cwc -- --print "summarise the README"
```

Everything after `--` is forwarded verbatim to `claude` inside the container, even if it looks like a PowerShell flag.

---

## Image lifecycle flags

### `cwc -Pull`

```powershell
cwc -Pull
```

Force `docker pull` of the configured image (`$env:CWC_IMAGE` or the default). Use this to refresh after a new release.

### `cwc -Build`

```powershell
cwc -Build
```

Build the image from the local `Dockerfile` next to `cwc.ps1`. Requires a full repo clone — fails if the launcher was installed via `install.ps1` only. Useful for contributors and one-off custom tweaks.

### `cwc -Force`

```powershell
cd C:\some\non-project-dir
cwc -Force
```

Bypass the project-root heuristic. The launcher normally refuses to run in a directory that doesn't look like a project root.

---

## `cwc firewall` — LAN-egress lockdown

**Per-project**, except `denylist` (global).

`cwc firewall {list, allow, deny, enable, disable, host-list, host-add, host-remove}` operate on the current project's config at `%USERPROFILE%\.cwc\projects\<slug>\config.json`. Run from inside a project root. They refuse with "no cwc config for this project yet — run `cwc setup` first" if the project hasn't been configured.

`cwc firewall denylist` is **global** (security policy applied to every project) and stored at `%USERPROFILE%\.cwc\config.json`. It's usable from anywhere.

Settings apply on the next `cwc` session in that project — no rebuild needed.

The lockdown blocks outbound traffic to RFC1918 ranges (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`) and IPv6 link-local / ULA. Public internet is unaffected. See [firewall.md](./firewall.md) for mechanics and threat model.

### `cwc firewall list`

```powershell
cwc firewall list
```

Show the current state: lockdown enabled/disabled, the CIDR allow-list, the FQDN host-mappings, and where the config file lives.

### `cwc firewall allow <cidr>`

```powershell
cwc firewall allow 192.168.50.0/24
cwc firewall allow 10.5.0.0/16
```

Re-allow a specific subnet through the lockdown. CIDRs persist across sessions.

### `cwc firewall deny <cidr>`

```powershell
cwc firewall deny 192.168.50.0/24
```

Remove a previously allowed CIDR.

### `cwc firewall enable` / `disable`

```powershell
cwc firewall disable    # turn the lockdown off entirely
cwc firewall enable     # turn it back on (default)
```

Toggle the lockdown without touching the allow-list. Disabling lets the container talk to anything on your network.

### `cwc firewall host-list`

```powershell
cwc firewall host-list
```

List the persistent FQDN → target mappings the entrypoint will write to the container's `hosts` file.

### `cwc firewall host-add <fqdn> [target] [ports]`

```powershell
cwc firewall host-add cm.ion.localhost                       # default: host-gateway, ports 443,80
cwc firewall host-add internal-api.local host-gateway 443    # 443 only
cwc firewall host-add legacy.box 10.5.1.20 8080              # explicit IP, port 8080
cwc firewall host-add db.local host-gateway 5432             # postgres on host
```

Add a host mapping. The entrypoint allocates a per-FQDN loopback IP (`127.0.0.X`), sets up `netsh portproxy` for each listed port, and writes the FQDN → loopback into the container's hosts file. Result: the agent reaches `<fqdn>:<listed-port>` via portproxy; other ports on that FQDN aren't bound and are unreachable.

`cwc firewall host-add` refuses any FQDN matching the denylist (`*.anthropic.com`, etc.) — see [`denylist`](#cwc-firewall-denylist-listaddremovereset) below.

For an explicit IP target in a private range, you also need a corresponding `cwc firewall allow <cidr>` so the lockdown doesn't blackhole it.

### `cwc firewall denylist {list|add|remove|reset}`

```powershell
cwc firewall denylist list                            # show active denylist
cwc firewall denylist add internal.example.com        # add a custom entry
cwc firewall denylist remove *.example.com            # remove (prompts if it's a default)
cwc firewall denylist reset                           # reset to defaults
```

FQDNs that `cwc firewall host-add` will refuse. Defaults cover Anthropic's auth-bearing channels (`*.anthropic.com`, `*.claude.ai`, `*.claude.com`, `*.anthropic.ai`) — preventing hosts-file injection from being used to MITM the API key. Custom entries let you protect additional FQDNs you care about (corporate auth, banking, etc.).

### `cwc firewall host-remove <fqdn>`

```powershell
cwc firewall host-remove cm.ion.localhost
```

Remove a mapping. The `hosts` file inside the next session won't include it.

---

## `cwc trust` — workspace policy file trust

**Per-project.** Trust state lives in the per-project config at `~/.cwc/projects/<slug>/config.json` under `trusted_files`.

Three files in your project drive what flows into the next session — `claude-sandbox.overlay.yml`, `.env`, `.mcp.json`. The agent has RW on the workspace, so any of these can be agent-edited. The trust system tracks per-project SHA-256 hashes and refuses to launch when they change without explicit ack. See [`security.md`](./security.md) for the threat model.

### `cwc trust`

```powershell
cwc trust                  # trust the current state of all tracked files in this project
```

Records SHA-256 hashes of the tracked files into the project's `trusted_files` map. Run this after legitimately editing one of the tracked files to dismiss the launch-time prompt.

### `cwc trust list`

```powershell
cwc trust list             # show trust state for tracked files in this project
```

Per-file status: `trusted` (current matches stored hash), `NEW` (file exists but isn't trusted), `MODIFIED` (file changed since last trust), `DELETED` (was trusted, now missing), `absent` (not present, never trusted).

### `cwc untrust`

```powershell
cwc untrust                # remove trust for this project; next 'cwc' will re-prompt
```

Wipes the per-project trust map. Useful if you want to force a fresh trust prompt (e.g., after a teammate sends you a PR with policy file changes).

---

## `cwc auth` — shared auth state

```powershell
cwc auth where             # print where shared and per-project state live
cwc auth reset             # wipe shared auth (~/.claude-win-container/auth/) — re-auth on next run
```

Per-project state (sessions, plugins, settings overlay) is unaffected by `auth reset`.

---

## `cwc harden` — tamper-resistant in-container hardening

**Per-project.** Each project's harden state is stored at `~/.cwc/projects/<slug>/config.json` and applies only to sessions launched from that project. `cwc harden enable` in project A does NOT enable harden in project B.

Opt-in. When enabled, the container runs an in-container watchdog every 2 seconds that re-applies blackhole routes, restores the hosts file from snapshot if changed, removes unauthorized `/32` allow-routes to RFC1918, and logs new trust-store CAs. The wizard recommends ON; you can toggle later. Not real isolation; see [`security.md`](./security.md) for the trade-offs.

```powershell
cwc harden enable          # turn on; takes effect on next 'cwc' session
cwc harden disable         # turn off
cwc harden status          # show state + what gets enforced + the limitations
```

---

## `cwc mount` — extra folder mounts

**Per-project.** Operates on the current project's config at `~/.cwc/projects/<slug>/config.json`. Refuses with "run `cwc setup` first" if the project isn't configured.

Mount additional folders from your host into the container. Common use cases: an Obsidian vault, design-spec folders, runbooks, anything claude should be able to read but isn't part of the project workspace.

Each mount is named. Inside the container, mounts land at a predictable path: `C:\docs\<name>`. Read-only is the default. A mount added in project A is NOT visible in project B.

### `cwc mount list`

```powershell
cwc mount list
```

Show all configured mounts: name, mode (`RO`/`RW`), host path, container path. Sources that no longer exist on disk are flagged as `(MISSING)` — they'll be skipped at session start with a warning until you fix the path.

### `cwc mount add <name> <host-path> [ro|rw]`

```powershell
cwc mount add obsidian C:\Users\you\Obsidian\Notes
cwc mount add specs C:\Users\you\Documents\design-specs
cwc mount add scratch C:\temp\scratch rw
```

Add a mount. The container path is auto-derived as `C:\docs\<name>`. Default mode is `ro` (readonly) — append `rw` to make it writable. Names must be alphanumeric (with `.`, `_`, `-` allowed) and can't collide with built-in container paths (`workspace`, `claude-data`, `command-history`, `claude-auth`).

If the host path doesn't exist when you add it, the mount is saved anyway with a warning — it'll be skipped at session start until the path appears. Useful when the path is sometimes-mounted (network share, removable drive).

### `cwc mount remove <name>`

```powershell
cwc mount remove obsidian
```

Remove a mount. Future `cwc` sessions won't include it.

### Read-only by default — why

Mounts default to read-only because the typical use case (notes, specs, runbooks) doesn't need writes from claude, and read-only mounts protect your source from a runaway agent. Use `rw` only when you genuinely want claude to be able to modify files.

The workspace mount (`C:\workspace`) is always read-write — that's the point.

---

## Environment variables

All read by the launcher and/or the entrypoint. Setting them in your shell or your project's `.env` overrides the user-wide config for that session.

| Variable | Description |
| --- | --- |
| `CWC_IMAGE` | Pin a specific image. Default: `fcostoya/claude-win-container:latest`. |
| `CWC_LOCKDOWN_LAN` | `1` (default) enables the LAN lockdown; `0` disables it. |
| `CWC_ALLOW_NETS` | Comma-separated CIDRs to re-allow (e.g. `192.168.50.0/24,10.5.0.0/16`). Merged with the user-wide allow-list. |
| `CWC_EXTRA_HOSTS` | Pipe-separated `fqdn|target|port,port` entries joined by `;` (e.g. `cm.local|host-gateway|443,80;db|10.5.1.20|5432`). Set automatically by `cwc firewall host-add`. |
| `CWC_HARDEN` | `1` enables the in-container watchdog; `0` (default) disables. |
| `CWC_SKIP_VERSION_CHECK` | `1` suppresses the GitHub-API call that drives the launch banner's "is this the latest stable?" check. The banner still prints, just without the freshness comparison. Useful in CI / offline environments. |

```powershell
# One-off override in the current shell:
$env:CWC_LOCKDOWN_LAN = '0'
cwc
```

`CWC_*` keys are read from your **shell environment** only. They are deliberately *not* forwarded from the project's `.env` — the agent has RW on the workspace, so allowing `.env` to drive sandbox flags would let it disable the lockdown silently. Persistent settings go through `cwc firewall ...` (writes `~/.cwc/config.json`); per-session overrides go through your shell. See [`security.md`](./security.md) for the rationale.

---

## State locations

| Path | What's there |
| --- | --- |
| `%USERPROFILE%\.cwc\` | Launcher install (`cwc.ps1`, `docker-compose.yml`, overlay example), and `config.json` from `cwc firewall *` / `cwc mount *`. |
| `%USERPROFILE%\.claude-win-container\auth\` | Shared Claude auth: OAuth tokens, API key cache, plugins, settings. |
| `%USERPROFILE%\.claude-win-container\projects\<slug>\` | Per-project Claude state: memory, sessions, todos, history. Slug = `<basename>-<sha1[0..11]>` of the project's absolute path. |
