# Commands reference

Every command and flag supported by `cwc` and the installer, with a short description and a usage example.

## Install / update

### `install.ps1` (one-shot installer)

```powershell
irm https://github.com/vinylflamingo/claude-win-container/releases/latest/download/install.ps1 | iex
```

Downloads `cwc.ps1`, `docker-compose.yml`, and the overlay example into `%USERPROFILE%\.cwc\`, then adds a `cwc` alias to your PowerShell `$PROFILE`. Idempotent — re-running updates files in place.

The install URL is stable across releases — `releases/latest/download/<asset>` always redirects to the most recent stable GitHub release (preview/* releases are flagged as prereleases and skipped). Older versions used a `raw.githubusercontent.com/.../main/...` URL that pulled from the `main` branch directly; that's no longer required.

**Flags:**

| Flag | Default | Description |
| --- | --- | --- |
| `-Ref <ref>` | `latest` | What to install. `latest` = most-recent stable release. A tag like `v1.2.3` = that exact release. A branch ref like `main` or `release/0.1.0` = raw files from that branch (dev / pre-release validation). |
| `-InstallDir <path>` | `%USERPROFILE%\.cwc` | Where to drop the launcher and config files. |
| `-LocalSource <path>` | (none) | Copy files from a local repo path instead of downloading from GitHub. Useful for development. |
| `-NoProfileEdit` | (off) | Skip writing the `cwc` alias to `$PROFILE`. |
| `-SkipFirewallSetup` | (off) | Skip the interactive firewall wizard. |
| `-Test` | (off) | Run end-to-end in an isolated sandbox: redirects `USERPROFILE` to a temp dir, defaults `LocalSource` to the script's own directory, leaves `$PROFILE` alone, and cleans everything up on exit. Walk the wizard, see your config.json dumped at the end, no permanent changes. |

```powershell
# Pin to a specific release tag. Install.ps1 is also published as a release
# asset, so the bootstrap URL and -Ref both point at the same tag.
$args = @('-Ref','v1.2.3')
irm https://github.com/vinylflamingo/claude-win-container/releases/download/v1.2.3/install.ps1 | iex

# Install from a branch (dev / pre-release validation)
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

Manages a persistent user-wide config at `%USERPROFILE%\.cwc\config.json`. Settings apply on the next `cwc` session — no rebuild needed.

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

Three files in your project drive what flows into the next session — `claude-sandbox.overlay.yml`, `.env`, `.mcp.json`. The agent has RW on the workspace, so any of these can be agent-edited. The trust system tracks a per-project SHA-256 of each and refuses to launch when they change without explicit ack. See [`security.md`](./security.md) for the threat model.

### `cwc trust`

```powershell
cwc trust                  # trust the current state of all tracked files in this project
```

Records SHA-256 hashes of the tracked files into `~/.cwc/config.json` under `trusted_files["<project-slug>"]`. Run this after legitimately editing one of the tracked files to dismiss the launch-time prompt.

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

Opt-in. When enabled, the container runs an in-container watchdog every 2 seconds that re-applies blackhole routes, restores the hosts file from snapshot if changed, removes unauthorized `/32` allow-routes to RFC1918, and logs new trust-store CAs. Off by default — turn on if you want a higher bar against agent tampering. Not real isolation; see [`security.md`](./security.md) for the trade-offs.

```powershell
cwc harden enable          # turn on; takes effect on next 'cwc' session
cwc harden disable         # turn off
cwc harden status          # show state + what gets enforced + the limitations
```

---

## `cwc mount` — extra folder mounts

Mount additional folders from your host into the container. Common use cases: an Obsidian vault, design-spec folders, runbooks, anything claude should be able to read but isn't part of the project workspace.

Each mount is named. Inside the container, mounts land at a predictable path: `C:\docs\<name>`. Read-only is the default. Persisted in the same `~/.cwc/config.json` as firewall settings.

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
