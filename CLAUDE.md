# Working on this project

Notes for Claude (or any agent / contributor) modifying `claude-win-container` itself. Not user-facing — for that, start at [`README.md`](./README.md). This file captures the things that aren't obvious from reading the code and that I learned the hard way during the security overhaul.

## What this project is

A Windows container image + PowerShell launcher (`cwc.ps1`) for running Claude Code in a sandbox. The launcher runs on the host; the entrypoint (`entrypoint.ps1`) runs inside the container at session start/end. The two share design but **not** code — they're literally separate scripts that load in different processes.

The repo's purpose is **not** to provide isolation against a determined attacker. It's a layered-defense "speed-bump" sandbox aimed at agents acting on wrong instructions or prompt injections. The honest security framing is in [`docs/security.md`](./docs/security.md). When in doubt, prefer that framing over marketing-mode language.

## Architecture quick-orient

| File | Role | Runs on |
| --- | --- | --- |
| `cwc.ps1` | Launcher: subcommand dispatch (`firewall`, `mount`, `trust`, `auth`, `harden`), config I/O, trust check, env-var forwarding, `docker compose run` | host |
| `entrypoint.ps1` | Container entrypoint: settings merge, LAN-egress lockdown, hosts-file management, harden watchdog, exit-time delta writeback | container |
| `Dockerfile` | Server Core + Node + Git + Claude Code + entrypoint | image build |
| `docker-compose.yml` | Service definition: bind mounts, env, isolation | host (parsed by `cwc.ps1`) |
| `install.ps1` | Interactive installer: security primer + 6-question wizard | host |
| `tests/run.ps1` + `tests/lib/harness.ps1` | Integration test runner: rewrites `~/.cwc/config.json` per test, spawns one-shot containers | host |
| `tests/*.tests.ps1` | Per-domain test files, auto-discovered | host |
| `tests/spikes/*.ps1` | One-off design-question scripts; not part of the regular suite | host |

## Hard rules

These are conventions I've encoded into the code and that future changes need to respect, or things break in ways the test suite won't always catch.

### 1. Validators are duplicated between `cwc.ps1` and `entrypoint.ps1`. Keep them in sync.

`Test-CwcFqdn`, `Test-CwcHostTarget`, `Test-CwcFqdnDenied` exist in both files. They have to — the launcher runs on the host (so `cwc.ps1`'s validators check user input at config-write time), and the entrypoint runs in the container (so `entrypoint.ps1`'s validators check `CWC_EXTRA_HOSTS` at hosts-file-write time, defense in depth in case config was hand-edited or env was set directly). The default Anthropic denylist (`*.anthropic.com` etc.) is also hardcoded in both.

If you change one, change the other. Search for `KEEP IN SYNC` comments.

### 2. `entrypoint.ps1` must be ASCII-only.

PowerShell 5.1 in the Server Core base image reads `.ps1` files using the system ANSI code page (Windows-1252), **not** UTF-8 — unless the file has a UTF-8 BOM. Multi-byte UTF-8 sequences (em-dashes `—`, arrows `→`, ellipses `…`, curly quotes) get reinterpreted as garbled bytes and break the parser at runtime with errors like:

```
Unexpected token 'would' in expression or statement.
```

(That's an em-dash inside a string literal — UTF-8 `0xE2 0x80 0x94` reread as `â€"`, where the stray `"` closes the string early.)

The CI workflow has a `Verify entrypoint.ps1 is ASCII-only` step that fails the build on any byte > 127. Don't bypass it — replace the offending character:

| Source | Replace with |
| --- | --- |
| `—` (em-dash) | `--` |
| `–` (en-dash) | `-` |
| `→` (right arrow) | `->` |
| `←` (left arrow) | `<-` |
| `…` (ellipsis) | `...` |
| `'` `'` (curly singles) | `'` |
| `"` `"` (curly doubles) | `"` |
| `═` (box drawing) | `=` |
| `✓` `×` etc. | `OK` / `x` / `*` |

This rule applies hardest to `entrypoint.ps1` (runs in the container, PS 5.1, ANSI code page). The other `.ps1` files run on the host where PowerShell 7 handles UTF-8 correctly, but we ASCII-fy them too as defense-in-depth — the cost is purely typographic.

When using the Edit/Write tool to modify any `.ps1` file, prefer ASCII alternatives by default. If you accidentally introduce a non-ASCII char and the CI lint catches it, run a one-shot replacement:

```powershell
$path = 'entrypoint.ps1'
$content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
$content = $content -replace '[—]', '--' -replace '[→]', '->' -replace '[…]', '...'
[System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::ASCII)
```

(Throws if any non-ASCII chars remain — the ASCII encoder fails on `?` substitution by default in some configs but the read/write round-trip will surface them.)

### 3. PowerShell 5.1 only — no PowerShell 7+ features.

Server Core ltsc2019 ships PowerShell 5.1. The container runs on it. Avoid:

- `ConvertFrom-Json -AsHashtable` (added in 6.x). Use `ConvertFrom-Json` and convert the resulting `PSCustomObject` to a hashtable manually — see `ConvertTo-CwcHashtable` in `entrypoint.ps1`.
- Ternary `?:` and null-coalescing `??` operators (7.0+).
- `Start-ThreadJob` (separate module, not built in to 5.1).
- `Test-Json`, `ConvertFrom-Yaml`, etc.

If you write something that won't work in 5.1, the test that exercises it will fail in a confusing way. Stick to 5.1-compatible idioms.

### 4. `CWC_*` env vars are NEVER read from project `.env`.

Sandbox-control flags (`CWC_LOCKDOWN_LAN`, `CWC_ALLOW_NETS`, `CWC_EXTRA_HOSTS`, `CWC_HARDEN`) come from the user's shell env (one-shot) or `~/.cwc/config.json` (persistent), and that's it. The agent has RW access to the workspace; if `.env` could drive these, the agent could write `CWC_LOCKDOWN_LAN=0` and disable the lockdown next launch. This is enforced in `cwc.ps1`'s forwarding loop — see the comment `# CWC_* keys can only come from shell env or user config`.

If you ever extend the env-forwarding rules, do not regress this.

### 5. The watchdog uses `Start-Job`, not `Start-Process`.

`Start-Process -WindowStyle Hidden` is unreliable in Server Core containers — there's no GUI subsystem, and `Hidden` requires one. `Start-Process -NoNewWindow` is also fragile. `Start-Job` runs in a child PowerShell runspace via the job system, which is purpose-built for long-running background work and works in headless environments. The watchdog explicitly `Import-Module NetTCPIP, NetAdapter` because module auto-loading is unreliable in job runspaces.

If the watchdog needs more stuff, prefer Start-Job and add explicit imports.

### 6. `netsh portproxy` requires `iphlpsvc`. The entrypoint starts it; if start fails, fall back gracefully.

Server Core ships `iphlpsvc` disabled. The entrypoint sets it to `Manual` startup and starts it before issuing any `netsh portproxy add`. If the start fails (service genuinely missing or refusing to start), the code falls back to the legacy direct-mapping behaviour (hosts file points at the gateway IP, `/32` allow-route, all ports reachable). Functionality is preserved; per-port narrowing is lost. The fallback prints a banner.

Don't remove the fallback. Don't assume `portproxy` always works.

### 7. Test environment-variable cleanup.

The test harness clears a list of "cwc-managed" env vars between tests (`$script:cwcManagedEnvVars` in `tests/lib/harness.ps1`). This list MUST contain every env var that `cwc.ps1` sets via the `if (-not $env:CWC_FOO) { $env:CWC_FOO = ... }` pattern. If you add a new env var with that pattern, add it to the cleanup list, or test pollution between tests will produce baffling failures (a test sets `HardenEnabled $true` but the container sees `CWC_HARDEN=0` because an earlier test left it set).

I learned this the hard way; it cost two test re-runs to find.

**Exception:** env vars that the harness sets *globally for the whole suite* (not per-test) shouldn't be in the cleanup list. `CWC_SKIP_VERSION_CHECK` is an example — the harness sets it once at load time so the launch banner's GitHub-API check never runs during tests. If it were in the cleanup list, the cleanup would unset it between tests and the next launch would hit the API. Two patterns, two purposes; don't conflate them.

### 8. Embedding JSON in `Invoke-InContainer` test commands is unreliable.

The test runner pipes commands through PowerShell → docker → PowerShell argv. Each layer can mangle quotes. **Single-quoted JSON literals embedded in a `-Command` string are particularly fragile** — quotes get eaten by some intermediate parser.

Two reliable patterns:
- **File staging**: write the desired content to a file in the workspace bind mount on the host, then have the container `Copy-Item` it into place. See `tests/settings-merge.tests.ps1`.
- **Construction inside the container**: build a hashtable in the container, then `ConvertTo-Json` and `Set-Content` from there. Avoids embedding JSON in the command string at all.

If a test starts mysteriously failing with empty / mangled JSON, it's almost always quoting.

### 9. Host-side tests use `Invoke-CwcOnHost`, not `Invoke-InContainer`.

Tests that exercise `cwc.ps1` behaviour (denylist, trust, harden config) use `Invoke-CwcOnHost`. It captures `*>&1` (all PowerShell streams), because `cwc.ps1` writes user-facing output via `Write-Host` which goes to the information stream — `2>&1` alone misses it.

Don't switch host-side tests to `Invoke-InContainer` thinking it's a more "complete" test. The two have different scopes:
- `Invoke-CwcOnHost` — exercises `cwc.ps1` (host-side, fast, no container start).
- `Invoke-InContainer` — exercises the entrypoint and container behaviour (slow, requires Docker, includes a container start).

### 10. Tests must be run with `-Build` after `entrypoint.ps1` or `Dockerfile` changes.

The default test target is `fcostoya/claude-win-container:latest` — the published image, which doesn't have your local changes. `tests/run.ps1 -Build` rebuilds from the local `Dockerfile` (writing to `:dev` by default) before running the suite.

If a container test starts behaving as if your entrypoint change isn't there, `-Build` is the fix.

## Workflow when changing things

1. Read [`docs/security.md`](./docs/security.md) for the threat model if you're touching anything sandbox-adjacent.
2. Make changes.
3. Run host-only tests for fast feedback: `.\tests\run.ps1 -Filter 'dev|denylist|trust|project-isolation|setup'` (~2 seconds; 29 tests).
4. If you touched the entrypoint or Dockerfile: `.\tests\run.ps1 -Build` (~5–8 minutes). For the inner loop on `entrypoint.ps1`, use `cwc dev` with `live_entrypoint_mount` set on — edits take effect on next launch with no rebuild.
5. Update docs:
   - New / changed user command → [`docs/commands.md`](./docs/commands.md).
   - New / changed network behaviour → [`docs/firewall.md`](./docs/firewall.md).
   - New / changed defense layer → [`docs/security.md`](./docs/security.md).
   - New / changed project-level file conventions → [`docs/per-project-setup.md`](./docs/per-project-setup.md).
   - New / changed CI/release behaviour → [`docs/release.md`](./docs/release.md).
   - User-visible behaviour change → [`README.md`](./README.md) (briefly).
6. Update [`CHANGELOG.md`](./CHANGELOG.md) if it's user-visible. Breaking changes get explicit "**This is a breaking change**" framing.

## Things to know about the codebase

- **Function definitions in `cwc.ps1` are hoisted to the top.** `Get-ProjectSlug` and the trust helpers used to live mid-file — I moved them up so the trust subcommand can use them. If you add a helper, put it in the helpers section near the top.
- **Subcommand dispatch in `cwc.ps1` uses `if ($Cmd[0] -eq 'foo')` chains, not a single `switch`.** Most blocks end with `exit 0` — they handle the subcommand fully and stop. The exception is `cwc dev` (session-launch path): it sets `$env:CWC_IMAGE`, builds `:dev` if missing, applies dev flags, strips `'dev'` from `$Cmd`, and **falls through** to the main launcher flow. That's deliberate — dev mode is just a different image, not a different code path. If you add a subcommand that should run *as if it were `cwc <command>` but with extra setup*, follow the dev pattern (set state, modify `$Cmd`, fall through). Otherwise stick to the `exit 0` pattern.
- **Config is split into global + per-project.** `~/.cwc/config.json` holds only the global denylist + defaults block. Per-project state (`lockdown_lan`, `harden_enabled`, `allow_nets`, `extra_hosts`, `mounts`, `trusted_files`) lives at `~/.cwc/projects/<slug>/config.json`, where `<slug>` is `Get-ProjectSlug` of the project's absolute path. The four config helpers — `Read-CwcGlobalConfig`, `Write-CwcGlobalConfig`, `Read-CwcProjectConfig`, `Write-CwcProjectConfig` — replace the old `Read-CwcConfig`/`Write-CwcConfig`. **Read-CwcProjectConfig returns `$null` when the project has no config yet** — that's the signal for the auto-setup wizard. Subcommands that mutate per-project state use `Get-RequiredCwcProjectConfig` which exits with an actionable error when there's no config.
- **`cwc dev` is session-scoped, not a persistent toggle.** Each `cwc dev` invocation explicitly opts in. The flag store at `~/.cwc/dev.json` is persistent (so flag settings stick across invocations), but the dev *mode* itself isn't. Adding a new dev flag: one entry in `$script:cwcDevFlagDefaults` plus per-flag handling in the dev session block (currently only `live_entrypoint_mount` exists, used as a template). Dev mode requires running from a clone (Dockerfile next to `cwc.ps1`); `Test-CwcInClone` is the gate.
- **Launch banner is filtered by `Invoke-InContainer`.** Lines starting with `[cwc]` and the `Project:`/`State:`/`Auth:`/`Command:`/`Forwarded:` summary block are stripped before assertions see them. Use `[cwc]` prefix for user-facing entrypoint banners; user-facing entrypoint *errors* should use a different prefix (or the test harness will silently swallow them). The new `[cwc] image: <tag> (...)` version banner is also filtered out.
- **Version banner does a network call** (24h-cached at `~/.cwc/version-cache.json`). Tests bypass it via `CWC_SKIP_VERSION_CHECK=1`, set globally by the harness. If you change anything about the banner's external dependencies (URL, response shape), update both `Get-CwcLatestStableVersion` and the cache schema.
- **`docker-compose.yml` is shipped to the user**. It lives next to `cwc.ps1` in `~/.cwc/`. Changes to it ship via the installer or by re-running `irm releases/latest/download/install.ps1`. If you add a new bind mount or env var here, the launcher needs to know how to set the corresponding compose-substitution variable.
- **The image is large (~6 GB)**. Server Core base + Node + Claude Code. Don't add packages casually; document in the Dockerfile if you do.
- **`IMPLEMENTATION_PLAN.md` is historical**. It captured the original v1 design before the security overhaul. It does not reflect current state. Read [`docs/security.md`](./docs/security.md) for current state. (TODO: archive or rewrite.)

## Test failure patterns I've seen

A reference for diagnosing test breakage:

| Symptom | Likely cause |
| --- | --- |
| Host-side test asserts `Should-Match 'X'` but actual output is empty | `Invoke-CwcOnHost` not capturing `Write-Host` — check `*>&1` |
| Container test sees old `entrypoint.ps1` behaviour | Forgot `-Build`; running against published image |
| Harden test: routes not re-applied | `CWC_HARDEN=0` in test output despite `-HardenEnabled $true` → env var not in `$cwcManagedEnvVars` cleanup list |
| Settings test: overlay not written | JSON quoting mangled through the `-Command` pipeline → use file staging |
| `[cwc] hosts skipped: ... (portproxy add failed for all ports)` | `iphlpsvc` not running and the fallback should have triggered — check that path |
| Smoke test fails with `Unexpected token 'would' in expression or statement` (or similar gibberish followed by tokens from a string body) | UTF-8 multi-byte char (em-dash, arrow, ellipsis) in `entrypoint.ps1` parsed as Windows-1252 by PS 5.1 in the container — see Hard rule #2. CI lint catches this on push, but local edits with the Edit tool can sneak chars in. ASCII-fy the file. |

## Cross-doc consistency

Several docs describe overlapping concepts. When updating one, check the others for stale references:

- **Network model**: `cwc.ps1` (firewall subcommand) ↔ `entrypoint.ps1` (CWC_EXTRA_HOSTS parser) ↔ `docs/firewall.md` ↔ `docs/security.md` (defense layers 2 & 3) ↔ `docs/commands.md` (env vars table) ↔ `README.md` (Common workflows + State and isolation).
- **Per-project config split**: `cwc.ps1` (config helpers, subcommand gates, main-flow auto-setup) ↔ `docs/security.md` ("Sandbox config split" section) ↔ `docs/commands.md` (per-subcommand "per-project" labels + `cwc setup` section) ↔ `docs/firewall.md` ("Managing the lockdown" section) ↔ `docs/per-project-setup.md` ("First-time setup: cwc setup") ↔ `README.md` (Quickstart) ↔ `tests/lib/harness.ps1` (`Set-CwcConfig` writes both global + per-project) ↔ `tests/run.ps1` (snapshots whole `~/.cwc/` tree).
- **Trust system**: `cwc.ps1` (trust helpers + main-flow trust check) ↔ `docs/security.md` (defense layer 4) ↔ `docs/commands.md` (cwc trust section) ↔ `docs/per-project-setup.md` (Trust system section) ↔ `README.md` (Troubleshooting first item). Trust state moved out of the global slug-keyed map into each project's `trusted_files` field — `Save-CwcProjectTrust` and `Get-CwcProjectTrustState` operate on the per-project config now.
- **Auth bind**: `entrypoint.ps1` (settings merge + delta) ↔ `docs/security.md` (Cross-project state).
- **Harden**: `cwc.ps1` (harden subcommand + env forwarding, per-project) ↔ `entrypoint.ps1` (watchdog block) ↔ `docs/security.md` (defense layer 5) ↔ `docs/commands.md` (cwc harden section) ↔ `cwc.ps1` (Q6 of `Invoke-CwcProjectSetup`) ↔ `README.md` (Common workflows).
- **`cwc dev`**: `cwc.ps1` (`0ba` subcommand block + `$script:cwcDevExtraMounts` injection in main-flow mountFlags) ↔ `docs/development.md` ("cwc dev" section) ↔ `docs/commands.md` (`cwc dev` + management subcommand sections) ↔ `docs/security.md` ("cwc dev and the threat model" section) ↔ `tests/dev.tests.ps1` ↔ `README.md` (Working on cwc itself: cwc dev).
- **Launch banner / version check**: `cwc.ps1` (`Get-CwcImageClassification`, `Get-CwcLatestStableVersion`, banner block before session summary) ↔ `docs/commands.md` (`CWC_SKIP_VERSION_CHECK` row in env-vars table) ↔ `tests/lib/harness.ps1` (sets `CWC_SKIP_VERSION_CHECK=1` globally).
- **CTF red-team suite**: `tests/ctf/` (lib + scenarios + run.ps1) ↔ `docs/ctf-suite.md` (architecture + design) ↔ `docs/security.md` ("Adversarial validation" section) ↔ `docs/development.md` (repo layout table) ↔ `tests/ctf/README.md` (operational reference). Status is tracked in both `docs/ctf-suite.md` and `tests/ctf/README.md` — keep both in sync.

When in doubt, search for the keyword across `*.md` files before changing one.
