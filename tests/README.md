# tests

Layer 1 isolation tests — deterministic, OS-level. Each test sets a known cwc config, opens a one-shot container shell via `cwc powershell -NoProfile -Command ...`, and asserts on the result.

## Run

```powershell
# Full suite (uses the published image — won't reflect uncommitted entrypoint.ps1 changes)
.\tests\run.ps1

# Build a fresh image from the local Dockerfile before running. REQUIRED when
# iterating on entrypoint.ps1 or Dockerfile — otherwise you're testing the
# published image, not your changes.
.\tests\run.ps1 -Build

# Pin a specific image (useful in CI for the matrix builds)
.\tests\run.ps1 -Image fcostoya/claude-win-container:0.1.1-ltsc2019

# Subset by name/category regex
.\tests\run.ps1 -Filter network
.\tests\run.ps1 -Filter 'dev|denylist|trust|project-isolation|setup'   # host-only suite, ~2s, no Docker

# Keep fixtures + config snapshot for inspection after a failure
.\tests\run.ps1 -NoCleanup
```

The runner snapshots your **entire** `~/.cwc/` tree before the suite (not just `config.json`) and restores it on exit. The per-project config layout means tests now write to `~/.cwc/projects/<slug>/config.json` and `~/.cwc/dev.json`, all of which get cleaned up. Fixtures live in `$env:TEMP\cwc-tests-<random>` and are removed unless `-NoCleanup` is passed.

The runner sets `CWC_SKIP_VERSION_CHECK=1` globally so the launch banner's "is this the latest stable?" GitHub-API call is skipped during tests.

## What's covered

| File | Scope |
| --- | --- |
| `filesystem.tests.ps1` | Container: workspace bind mount, host-path invisibility, configured RO/RW mounts at `C:\docs\<name>`, missing-source mount handling |
| `network.tests.ps1` | Container: LAN-egress lockdown blackhole routes, allow-CIDR pinholes, public-internet reachability, host-gateway portproxy + loopback hosts file mapping + /32 allow, env override |
| `auth.tests.ps1` | Container: per-project state isolation, shared global auth dir |
| `settings-merge.tests.ps1` | Container: settings.json deep-merge of global + per-project overlay, project additions never mutate global |
| `harden.tests.ps1` | Container: watchdog re-applies removed blackhole, removes unauthorized routes, restores hosts file |
| `denylist.tests.ps1` | Host-side: `cwc firewall host-add` denylist enforcement, FQDN/target validation, global denylist add/remove/reset |
| `trust.tests.ps1` | Host-side: `cwc trust`/`untrust`, trust state detection for `.env`/`.mcp.json`/`claude-sandbox.overlay.yml` |
| `setup.tests.ps1` | Host-side: per-project subcommands (`firewall`, `mount`) refuse with no project config; denylist (global) works without one |
| `project-isolation.tests.ps1` | Host-side: `extra_hosts`, `allow_nets`, `harden_enabled` set in project A do NOT leak into project B; denylist is global and visible from both |
| `dev.tests.ps1` | Host-side: `cwc dev flag {list,set,unset}` persistence, status output, host-side subcommand wrapping rejected, unknown-flag and bad-value handling |

Container tests take ~5–15 seconds each (container startup dominates); host-only tests are ~0.2s each. The host-only filter (`dev|denylist|trust|project-isolation|setup`) runs all 29 host-side tests in ~2 seconds — use it as your inner dev loop. Full suite (with `-Build`) is ~5–8 minutes.

## Adding tests

Drop a new `*.tests.ps1` file in this directory; the runner auto-discovers them. Available helpers (from `lib/harness.ps1`):

- `Run-TestCase -Category <name> -Name <test> -Test { ... }` — wrap each assertion.
- `Set-CwcConfig [-LockdownLan <bool>] [-AllowNets @(...)] [-ExtraHosts @{}] [-Mounts @{}] [-HostDenylist @(...)] [-HardenEnabled <bool>] [-TrustedFiles @{}] [-ProjectDir <path>]` — replace **both** `~/.cwc/config.json` (global denylist + defaults) and `~/.cwc/projects/<slug>/config.json` (per-project) with a known state. `-ProjectDir` defaults to the fixture workspace, matching `Invoke-InContainer`'s default. Tests targeting a different fixture project (project-isolation, setup) pass `-ProjectDir` explicitly. Each call writes the full config; defaults are conservative (lockdown on, harden off, default Anthropic denylist).
- `Get-CwcSlugForTest <path>` — mirror of `cwc.ps1`'s `Get-ProjectSlug`. Use when you need to compute a project's config path independently (e.g., to assert a file exists or to clean up between tests).
- `Invoke-InContainer 'powershell-command' [-WorkDir <path>] [-Env @{}]` — run inside a one-shot container; defaults to the fixture workspace. Use this for tests that exercise entrypoint / container behaviour.
- `Invoke-CwcOnHost -Args @('firewall','host-add','...') [-WorkDir <path>]` — run a `cwc` subcommand on the host (no container start). Defaults `-WorkDir` to the fixture workspace too, so the project that `Set-CwcConfig` configures matches the project `cwc` operates on. Captures all PowerShell streams via `*>&1`. Returns `@{ ExitCode = ...; Output = ... }`.
- `Should-Match`, `Should-NotMatch`, `Should-BeTrue`, `Should-Equal`, `Should-NotEqual` — throw on failure with helpful messages.

## What this doesn't test

- **Adversarial prompts.** Whether claude tries to violate a boundary depends on prompts + model behaviour and isn't deterministic. Out of scope here (Layer 2 in the original plan).
- **Determined attackers inside the container.** Code running as Administrator can `Remove-NetRoute` and re-enable LAN access. The lockdown is speed-bump defense; tests assert the speed-bump exists, not that it's unbypassable.
- **Hostile-content public IPs.** Egress to public IPs isn't restricted by design; nothing to test.
