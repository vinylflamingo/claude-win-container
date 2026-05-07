# Development

How to work on `claude-win-container` itself: clone, run, build, test, debug, contribute. End users don't need this — start at [`README.md`](../README.md). Maintainer-facing release process is in [`release.md`](./release.md).

If you're using Claude Code (or any agent) to make changes, also read [`../CLAUDE.md`](../CLAUDE.md) — it captures hard-won rules (validators that must stay in sync, ASCII-only constraint on `entrypoint.ps1`, PS 5.1 compatibility, env-var cleanup in tests, etc.). The notes below are scoped to "how do I get a working dev loop"; CLAUDE.md is the deeper "what will trip me up."

## Repo layout

| File | Where it runs | Purpose |
| --- | --- | --- |
| `cwc.ps1` | Host (PS 7) | Launcher — subcommand dispatch, config I/O, env wiring, `docker compose run` |
| `entrypoint.ps1` | Container (PS 5.1) | Settings merge, LAN-egress lockdown, hosts-file management, harden watchdog, exit-time delta writeback |
| `install.ps1` | Host (PS 7) | One-shot installer: drops files into `~/.cwc/`, adds `$PROFILE` alias |
| `Dockerfile` | Image build | Server Core + Node + Git + Claude Code + entrypoint |
| `docker-compose.yml` | Host (parsed by `cwc.ps1`) | Service definition: bind mounts, env, isolation |
| `tests/run.ps1` | Host | Test runner: snapshots `~/.cwc/`, seeds fixtures, auto-discovers `*.tests.ps1` |
| `tests/lib/harness.ps1` | Host | Shared test helpers — `Set-CwcConfig`, `Invoke-InContainer`, `Invoke-CwcOnHost`, `Should-*` assertions |
| `tests/spikes/` | Host | One-off design-question scripts; not part of the regular suite |

## Pre-requisites

- Windows 10/11 or Server 2019+ with **Docker Desktop in Windows-containers mode** (Linux mode won't work — the image is Server Core).
- PowerShell 7 on the host (for editor/launcher work). PS 5.1 ships with Windows; the container runs that.
- Git.
- ~10 GB of disk for the base image + your local builds.

Verify Docker mode:

```powershell
docker info | Select-String 'OSType|Operating System'
# Expect: OSType: windows
```

If it says `linux`, right-click the Docker Desktop tray icon → "Switch to Windows containers..."

## Clone and run from your working tree

The installed `cwc` alias points at `~/.cwc/cwc.ps1` (the version `install.ps1` dropped). When developing, you want it to point at your **clone** so edits take effect immediately.

```powershell
git clone https://github.com/vinylflamingo/claude-win-container
cd claude-win-container

# Option A: dot-source for the current session only
Set-Alias cwc (Resolve-Path .\cwc.ps1)
cwc help

# Option B: edit your $PROFILE so every new shell uses the clone
notepad $PROFILE
# Replace the line:
#   Set-Alias cwc 'C:\Users\you\.cwc\cwc.ps1'
# with:
#   Set-Alias cwc 'C:\Users\you\Projects\claude-win-container\cwc.ps1'
```

Either way, `cwc` now executes the file you're editing.

## `cwc dev` — session-scoped dev mode

The recommended dev loop. Run `cwc dev` instead of `cwc` and the launcher uses a local `:dev` image (built from the Dockerfile next to `cwc.ps1`) for **just that invocation**. Leaving the session puts you back in normal mode — there's no persistent "I'm in dev now" state to forget about.

```powershell
cd C:\path\to\my-project
cwc dev                        # launches claude in :dev container; builds the image if missing
cwc dev powershell             # drop to a shell inside the :dev container
cwc dev mcp list               # any normal cwc command works under `dev`
```

Requires running from a clone (Dockerfile must sit next to `cwc.ps1`). Refuses host-side subcommands (`cwc dev firewall list`, etc.) since those don't start a container — just use `cwc firewall list` directly.

### Management subcommands

```powershell
cwc dev build       # docker compose build claude-code (against :dev tag)
cwc dev rebuild     # remove :dev image, then build --no-cache
cwc dev clean       # remove the :dev image
cwc dev status      # show :dev image presence + clone path + flag values
```

### Persistent flags

Flag values live at `~/.cwc/dev.json` and apply to every `cwc dev` session until you change them. (The dev *mode* itself is session-scoped; only the flag *settings* persist.)

```powershell
cwc dev flag list                                       # show all flags + values + defaults
cwc dev flag set live_entrypoint_mount on               # turn on
cwc dev flag set live_entrypoint_mount off              # turn off
cwc dev flag unset live_entrypoint_mount                # reset to default
```

Available flags:

| Flag | Default | Effect |
| --- | --- | --- |
| `live_entrypoint_mount` | off | Bind-mount the clone's `entrypoint.ps1` over `C:\entrypoint.ps1` inside the `:dev` container (read-only). Edits to `entrypoint.ps1` take effect on the next `cwc dev` launch with **no rebuild required** — huge productivity win when iterating on entrypoint behavior. Remember to flip it off (or do a normal `cwc`) when you want to test the baked-in image behavior. |

### Manual build (without `cwc dev`)

```powershell
docker compose build claude-code
```

This builds an image tagged `fcostoya/claude-win-container:latest` (the default in `docker-compose.yml`). First build is ~5–10 minutes; subsequent builds are layer-cached and fast unless you've touched the Dockerfile. Mostly you'll want `cwc dev build` instead so you don't shadow the published `:latest`.

The CI matrix builds for both `ltsc2019` (default base) and `ltsc2022`. Locally you only build the one that matches your host's compatibility — the `BASE_IMAGE` build arg controls it. Stick to defaults unless you need the other.

## Running tests

Two tiers. Default to the fast tier during development; run the full suite before pushing a release branch.

### Fast tier — host-side only (~2 seconds)

No container start. Exercises `cwc.ps1` directly.

```powershell
.\tests\run.ps1 -Filter 'denylist|trust|project-isolation|setup'
```

Use this as your inner dev loop when changing `cwc.ps1`. It covers config I/O, the firewall denylist, trust system, project isolation, and the auto-setup gate.

### Full tier — container behavior (~5–8 minutes)

Spins up containers; tests `entrypoint.ps1` and the integrated network/filesystem/auth/harden behavior.

```powershell
.\tests\run.ps1 -Build
```

`-Build` rebuilds the image first — **required** when you've touched `entrypoint.ps1` or `Dockerfile`, otherwise you're testing the published image, not your changes. Without `-Build`, the runner uses whatever image `CWC_IMAGE` points at (default: the published one).

Other flags:

```powershell
.\tests\run.ps1 -Filter network          # only network-* tests
.\tests\run.ps1 -NoCleanup               # keep fixtures + ~/.cwc snapshot for inspection
.\tests\run.ps1 -Image fcostoya/claude-win-container:0.1.1-ltsc2019
```

The runner snapshots your real `~/.cwc/` tree before the suite and restores it on exit (success or failure). Fixtures live in `$env:TEMP\cwc-tests-<random>`.

See [`tests/README.md`](../tests/README.md) for the test catalog and harness API.

## Debugging

### Inspect launcher behavior on the host

Add `Write-Host` near the suspect code in `cwc.ps1`. The launcher's stdout is your terminal — output appears immediately.

For a verbose dump of what the launcher computes:

```powershell
cwc firewall list                # current project's firewall config
cwc auth where                   # state directories
cwc trust list                   # workspace policy file trust state
```

If the launcher is computing the wrong project slug or config path, surface it:

```powershell
# In cwc.ps1, add one line before the affected code:
Write-Host "[debug] slug=$slug project=$projectDir cfg=$(Get-CwcProjectConfigPath $slug)" -ForegroundColor Magenta
```

### Inspect container behavior

Drop to a shell inside a one-shot container, no `claude` running:

```powershell
cd C:\path\to\some-project
cwc powershell
# you're now inside the container; explore freely
PS C:\workspace> Get-NetRoute | Where-Object NextHop -eq '0.0.0.0'   # check blackhole routes
PS C:\workspace> Get-Content C:\Windows\System32\drivers\etc\hosts   # check hosts-file mappings
PS C:\workspace> netsh interface portproxy show all                  # check portproxy listeners
PS C:\workspace> Get-Content C:\cwc-watchdog\watchdog.log -Tail 50   # if harden enabled
```

The container exits when you `exit`. State written to `C:\workspace` (the bind-mounted project) persists; everything else is ephemeral.

### Get the entrypoint to log

`entrypoint.ps1` runs at session start and writes user-facing banners prefixed `[cwc]`. To see what it's doing during startup, just watch the launcher output — the entrypoint's stdout is forwarded.

For deeper inspection, add `Write-Host '[cwc] debug: ...'` lines and rebuild with `-Build`. Don't use Unicode characters (em-dashes, arrows, ellipses) — the file is parsed under the Windows-1252 code page and breaks at runtime. See CLAUDE.md hard rule #2.

### Reset state

If your local `~/.cwc/` gets into a bad state (corrupted config, stale trust hashes), nuke it:

```powershell
Remove-Item -Recurse -Force ~\.cwc
# next 'cwc' triggers a fresh setup wizard
```

This doesn't touch `~/.claude-win-container/` (which holds session state, plugins, auth tokens). To reset auth too:

```powershell
cwc auth reset
```

To wipe per-project session state too:

```powershell
Remove-Item -Recurse -Force ~\.claude-win-container
```

## Iteration loops

Recommended development cadences for the common change shapes:

| You're changing... | Loop |
| --- | --- |
| `cwc.ps1` (launcher logic, subcommand dispatch, config I/O) | Edit → `.\tests\run.ps1 -Filter 'dev\|denylist\|trust\|project-isolation\|setup'` (~2s) |
| `entrypoint.ps1` (container-side behavior) | One-time: `cwc dev build` and `cwc dev flag set live_entrypoint_mount on`. Then: edit → `cwc dev` (no rebuild) → repeat. Run `.\tests\run.ps1 -Build -Filter network` (~3 min) before commit. |
| `Dockerfile` (image contents) | Edit → `cwc dev rebuild` → `cwc dev powershell` to verify → full `.\tests\run.ps1 -Build` before commit |
| `install.ps1` | Edit → `.\install.ps1 -Test` (sandboxed, no real changes) |
| `docker-compose.yml` | Edit → `cwc dev rebuild` → `.\tests\run.ps1 -Build` (compose changes affect mounts/env, container tests cover them) |

## Contributing

1. Branch off `main`. Use a descriptive name (`feature/...`, `fix/...`, `docs/...`). Never push directly to `main` — it's post-release-only and CI doesn't run on it (see [`release.md`](./release.md)).
2. Make changes. Read the [hard rules in CLAUDE.md](../CLAUDE.md#hard-rules) — they encode failure modes that aren't obvious from the code alone (validators that must stay in sync between `cwc.ps1` and `entrypoint.ps1`, the ASCII-only requirement, PS 5.1 compatibility, env-var cleanup in tests).
3. Run the fast test tier (`-Filter 'denylist|trust|...'`) every few edits — it's 2 seconds.
4. Before opening a PR or pushing a `preview/*`/`release/*` branch, run the full tier with `-Build` if you touched anything below the launcher (entrypoint, Dockerfile, compose).
5. Update docs alongside code:
   - User-visible CLI change → [`commands.md`](./commands.md), maybe [`README.md`](../README.md).
   - Network-model change → [`firewall.md`](./firewall.md), [`security.md`](./security.md).
   - New defense layer or threat-model shift → [`security.md`](./security.md).
   - Per-project file convention → [`per-project-setup.md`](./per-project-setup.md).
   - CI / release behavior → [`release.md`](./release.md).
6. Add a [`CHANGELOG.md`](../CHANGELOG.md) entry under `[Unreleased]` for any user-visible change. Mark breaking changes explicitly: **This is a breaking change**.
7. Open a PR against `main`. CI doesn't run on PRs (only on `release/*` and `preview/*`); maintainers validate locally and via a `preview/*` branch before promoting.

## Validating a release candidate end-to-end

Before tagging a real release, push a `preview/<version>` branch. CI runs the full pipeline (lint, host-tests, build for both ltsc2019 + ltsc2022, smoke, push to Docker Hub *without* `:latest`, create a GitHub pre-release) without committing to a stable version. Pull the pre-release image on a fresh machine, run through the install + first-project flow, and confirm everything works. Only then cut a `release/*` branch.

Full release process: [`release.md`](./release.md).

## Common mistakes

- **Editing `entrypoint.ps1` and forgetting `-Build`.** Tests will pass against the published image, then the container fails when you actually run it. Symptom: container test passes, real `cwc` session breaks.
- **Pasting an em-dash, arrow, or curly quote into `entrypoint.ps1`.** Runtime parser blows up with a misleading "Unexpected token" error. CI lint catches this on push, but local edits sneak it in. ASCII-fy.
- **Adding a new `CWC_*` env var without updating `$cwcManagedEnvVars` in `tests/lib/harness.ps1`.** Test pollution between runs produces baffling failures (a test sets `HardenEnabled $true` but the container sees `CWC_HARDEN=0` because an earlier test left it set).
- **Embedding a JSON literal in an `Invoke-InContainer` command string.** Quotes get mangled through the PowerShell → docker → PowerShell argv pipeline. Use file staging (write to the workspace bind mount on the host, `Copy-Item` inside the container) or build the hashtable inside the container and `ConvertTo-Json` there. See `tests/settings-merge.tests.ps1`.
- **Modifying validators in `cwc.ps1` without mirroring the change in `entrypoint.ps1`.** They're duplicated by design (different processes, different code paths). Search for `KEEP IN SYNC` comments.
