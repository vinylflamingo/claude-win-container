# Per-project setup

What a project repo needs (or doesn't) to opt into the sandboxed Claude container. The launcher (`cwc.ps1`) is invoked from the **project's** working directory, not from this repo.

## Required: nothing

If your project root contains any of `.git`, `package.json`, `*.sln`, `.mcp.json`, `pyproject.toml`, `go.mod`, or `Cargo.toml`, the launcher will accept it as a project root and run. No files in your repo need to change.

```powershell
cd C:\Users\you\Projects\my-app
cwc                       # boots Claude in a sandboxed container, mounts the repo at C:\workspace
```

## Optional: `.mcp.json`

If your project uses MCP servers, ship a `.mcp.json` at the project root the way Claude Code expects. The launcher reads it for two reasons:

1. **Env-var forwarding.** Any key referenced as `${KEY}` in `.mcp.json` is automatically forwarded from the project's `.env` (or current process env) into the container. So if your MCP server wants `${SUPABASE_URL}`, just set `SUPABASE_URL=...` in `.env` and it lands inside the container — no extra config.
2. **Documentation.** The launcher will surface the keys it's forwarding in the startup banner so you can see what's leaking into the container.

`.mcp.json` itself doesn't need anything special — same format Claude Code already uses.

### Starter `.mcp.json`

Copy [`examples/mcp.example.json`](../examples/mcp.example.json) to your project root and trim to taste:

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    }
  }
}
```

Set `GITHUB_TOKEN=...` in `.env` (or your shell), and the launcher forwards it because `.mcp.json` references `${GITHUB_TOKEN}`. Other keys in `.env` are ignored unless they match the rules below.

### Editing `.mcp.json` from `cwc`

Three options, all writing to the same file (the project root is bind-mounted RW):

```powershell
# Option 1 — edit on the host with your normal editor
code .mcp.json

# Option 2 — Claude's built-in MCP commands, run inside the container via cwc
cwc mcp list
cwc mcp add <name> -- npx -y @some/mcp-server
cwc mcp remove <name>

# Option 3 — drop into a container shell and edit
cwc powershell
# inside: Set-Content .mcp.json '{ ... }'
```

`cwc mcp ...` is a passthrough shorthand for `cwc claude mcp ...` — the launcher detects `mcp` as the first arg and prepends `claude`. Changes show up immediately on the host (and in claude on the next `cwc` invocation, since claude reads `.mcp.json` at startup).

The first time a project uses an MCP server, claude (via `npx`) will fetch it from npm — make sure `registry.npmjs.org` isn't blocked by anything between the container and the internet. Public egress is allowed by default in cwc; the [LAN lockdown](./firewall.md) only blocks RFC1918.

## Optional: `.env`

The launcher parses `$PWD/.env` and forwards a **curated** set of keys (it does NOT forward the whole file — your DB password and S3 keys stay home unless you ask):

| Key pattern | Forwarded |
| --- | --- |
| `ANTHROPIC_API_KEY` | yes |
| `CLAUDE_CODE_OAUTH_TOKEN` | yes |
| `CLAUDE_*` | yes (consumer-defined Claude config) |
| `ANTHROPIC_*` | yes |
| Any `${KEY}` referenced in `.mcp.json` | yes |
| `CWC_*` | **no** — sandbox flags, host shell env only (see [security.md](./security.md)) |
| Anything else | **no** |

Empty values are filtered out. Secrets (keys matching `KEY|TOKEN|SECRET|PASSWORD`) are masked in the startup banner.

To extend the allowlist on a one-off basis, set the env var in your shell *before* invoking `cwc` — the launcher checks the process environment as a fallback when a key isn't in `.env`.

`CWC_*` keys (`CWC_LOCKDOWN_LAN`, `CWC_ALLOW_NETS`, `CWC_EXTRA_HOSTS`, `CWC_HARDEN`) deliberately bypass the `.env` path. They control the sandbox itself, and the agent has RW on the workspace — letting `.env` drive them would let the agent silently disable the lockdown on the next launch. Persistent values go through `cwc firewall ...` / `cwc harden ...` (which write `~/.cwc/config.json`); one-shot overrides go through your shell.

## Optional: `claude-sandbox.overlay.yml`

A docker-compose overlay the launcher auto-includes when present in the project root. Use it for things the base container deliberately doesn't bake in:

- Attach the container to a sibling docker-compose stack's network (so Claude can reach `cm`, `db`, etc. by short hostname).
- Mount extra read-only paths (Obsidian vaults, design specs, runbooks). For most cases prefer `cwc mount add` — same effect, no overlay needed.
- Override mem/cpu limits for the project.

Copy [`overlays/project-overlay.example.yml`](../overlays/project-overlay.example.yml) and adapt. **Do not** override the standard mount paths (`C:\workspace`, `C:\claude-data`, `C:\command-history`, `C:\claude-auth`).

If you commit the overlay, future contributors get the same network/mounts automatically. If you'd rather keep it personal, gitignore it.

> The overlay is **trusted explicitly per project**. The first time you run `cwc` in a project that contains an overlay (or after the file's contents change), the launcher prompts you to confirm before loading it. Run `cwc trust` to ack the current state. See [`security.md`](./security.md) for why.

## Trust system

Three files in your project root drive what flows into the next session:

| File | Effect on the next session |
| --- | --- |
| `claude-sandbox.overlay.yml` | Compose overlay auto-loaded by the launcher — can add mounts, attach networks, change isolation. |
| `.env` | Environment variables forwarded into the container (per the allowlist above). |
| `.mcp.json` | MCP servers + extra `${KEY}` references that get forwarded from your shell env. |

The agent has RW on the workspace, which means it can edit any of these files. Without something stopping it, the agent could silently expand its next session's sandbox by editing the workspace.

The trust system tracks per-project SHA-256 of these three files in `~/.cwc/config.json` under `trusted_files["<project-slug>"]`. Before launching the container, the launcher checks each tracked file's hash against what was stored last time you ran `cwc trust`. The behaviour on mismatch:

- **Interactive session** (real terminal): the launcher shows per-file status (`trusted` / `NEW` / `MODIFIED` / `DELETED`) and prompts `Trust current state and continue? [y/N]`. Answering `y` saves the new hashes and proceeds.
- **Non-interactive session** (CI, scripted, redirected stdin): the launcher refuses to launch with a clear `Run 'cwc trust' to acknowledge` message. No silent inheritance.

### First run in a project

The first time you run `cwc` in a project that has any of the three tracked files, you'll see the trust prompt. This is intentional — even a fresh-from-clone repo should require an explicit ack before the agent inherits whatever overlay/env/mcp config is committed there. Trust on first use, not silent first use.

If the project has none of those files (e.g. a Python project with only `pyproject.toml`), no prompt — there's nothing to trust.

### Managing trust state

```powershell
cwc trust              # ack the current state of all tracked files in this project
cwc trust list         # show the per-file status without changing anything
cwc untrust            # drop trust state for this project (forces a re-prompt next launch)
```

`cwc untrust` is useful after pulling a PR with overlay/`.env`/`.mcp.json` changes — it forces the next `cwc` to re-prompt so you'll see what was added/changed before it takes effect.

### What the trust system does NOT cover

- **Project source code.** The agent has RW on the workspace; that's the point. Trust covers only the three sandbox-driving files above.
- **Determined adversaries.** The trust prompt is a guard rail. If you click `y` without reading the diff, you've trusted whatever was added. Use `cwc trust list` first if you're not sure what changed.
- **The OAuth token / API key.** Those are not trust-tracked because they live outside the workspace (in `~/.claude-win-container/auth/.credentials.json`).

For the wider security model, see [`security.md`](./security.md).

## Optional: `.gitignore` additions

If your project ignores `.env` and editor state already, you probably don't need anything else. If you ship a `claude-sandbox.overlay.yml` and want it gitignored, add:

```
claude-sandbox.overlay.yml
```

## State location

Everything Claude writes for *this project* lives at:

```
%USERPROFILE%\.claude-win-container\projects\<basename>-<sha1[0..11]>\
  config\                       # CLAUDE_CONFIG_DIR (sessions, todos, plans, history.jsonl)
    settings.json               #   merged result Claude reads (regenerated each session)
    settings-project.json       #   per-project delta vs. global (this project's overrides)
    plugins\                    #   per-project plugins (was global pre-overhaul; moved)
    cache\, statsig\, telemetry\ #  per-project caches
    sessions\, todos\, plans\, projects\, ...
  history\                      # shell history (per-project)
```

Shared across all projects (just OAuth tokens + global preferences):

```
%USERPROFILE%\.claude-win-container\auth\
  .credentials.json             # OAuth tokens (whole-file global, refreshed by Claude)
  mcp-needs-auth-cache.json     # small cache (whole-file global)
  settings.json                 # global preferences (theme, telemetry, autoUpdater); deep-merged
                                # with per-project settings-project.json on entry, never mutated by sessions
```

The slug is stable: `<basename>-<sha1[0..11]>` of the absolute project path. Two projects with the same basename get different slugs (different paths → different sha1).

`settings.json` is **per-project effectively** — see [`security.md`](./security.md) for how the deep-merge works. Anything an agent installs (MCP servers, hooks, permissions) lands in the per-project overlay, not global. So an agent in project A can't plant config that runs in project B.

## Checking what gets forwarded

Before kicking off a real session, you can see exactly what env will land in the container:

```powershell
cwc powershell -NoProfile -Command 'Get-ChildItem env: | Sort-Object Name | Format-Table -AutoSize'
```

## What if my project doesn't pass the heuristic?

If the directory has none of `.git`/`package.json`/`*.sln`/`.mcp.json`/`pyproject.toml`/`go.mod`/`Cargo.toml`, the launcher refuses to start. Either add an empty marker (`git init` is the easiest) or use `cwc -Force` to override.
