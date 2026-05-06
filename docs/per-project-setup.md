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
| Anything else | **no** |

Empty values are filtered out. Secrets (keys matching `KEY|TOKEN|SECRET|PASSWORD`) are masked in the startup banner.

To extend the allowlist on a one-off basis, set the env var in your shell *before* invoking `cwc` — the launcher checks the process environment as a fallback when a key isn't in `.env`.

## Optional: `claude-sandbox.overlay.yml`

A docker-compose overlay the launcher auto-includes when present in the project root. Use it for things the base container deliberately doesn't bake in:

- Attach the container to a sibling docker-compose stack's network (so Claude can reach `cm`, `db`, etc. by short hostname).
- Map hostnames to `host-gateway` so requests hit Traefik on the host.
- Mount extra read-only paths (Obsidian vaults, design specs, runbooks).
- Override mem/cpu limits for the project.

Copy [`overlays/project-overlay.example.yml`](../overlays/project-overlay.example.yml) and adapt. **Do not** override the standard mount paths (`C:\workspace`, `C:\claude-data`, `C:\command-history`, `C:\claude-auth`).

If you commit the overlay, future contributors get the same network/mounts automatically. If you'd rather keep it personal, gitignore it.

## Optional: `.gitignore` additions

If your project ignores `.env` and editor state already, you probably don't need anything else. If you ship a `claude-sandbox.overlay.yml` and want it gitignored, add:

```
claude-sandbox.overlay.yml
```

## State location

Everything Claude writes about the *project* lives at:

```
%USERPROFILE%\.claude-win-container\projects\<basename>-<sha1[0..11]>\
  config\        # CLAUDE_CONFIG_DIR (memory, sessions, todos, plans, history.jsonl)
  history\       # shell command history
```

Auth (OAuth tokens, API key cache, plugins, shared user prefs) is shared across projects:

```
%USERPROFILE%\.claude-win-container\auth\
  .credentials.json
  settings.json
  plugins/
  cache/
  ...
```

The slug is stable: `<basename>-<sha1[0..11]>` of the absolute project path. Two projects with the same basename get different slugs (different paths → different sha1).

## Checking what gets forwarded

Before kicking off a real session, you can see exactly what env will land in the container:

```powershell
cwc powershell -NoProfile -Command 'Get-ChildItem env: | Sort-Object Name | Format-Table -AutoSize'
```

## What if my project doesn't pass the heuristic?

If the directory has none of `.git`/`package.json`/`*.sln`/`.mcp.json`/`pyproject.toml`/`go.mod`/`Cargo.toml`, the launcher refuses to start. Either add an empty marker (`git init` is the easiest) or use `cwc -Force` to override.
