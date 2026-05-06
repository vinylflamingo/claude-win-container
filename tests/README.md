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
.\tests\run.ps1 -Image fcostoya/claude-win-container:0.1.0-alpha-ltsc2019

# Subset by name/category regex
.\tests\run.ps1 -Filter network
.\tests\run.ps1 -Filter 'denylist|trust'   # host-only suite, ~10s, no Docker

# Keep fixtures + config snapshot for inspection after a failure
.\tests\run.ps1 -NoCleanup
```

The runner snapshots your real `~/.cwc/config.json` before the suite and restores it on exit (success or failure). Fixtures live in `$env:TEMP\cwc-tests-<random>` and are removed unless `-NoCleanup` is passed.

## What's covered

| File | Scope |
| --- | --- |
| `filesystem.tests.ps1` | Workspace bind mount, host-path invisibility, configured RO/RW mounts at `C:\docs\<name>`, missing-source mount handling |
| `network.tests.ps1` | LAN-egress lockdown blackhole routes, allow-CIDR pinholes, public-internet reachability, host-gateway portproxy + loopback hosts file mapping + /32 allow, env override |
| `auth.tests.ps1` | Per-project state isolation, shared global auth dir |
| `denylist.tests.ps1` | Host-side: `cwc firewall host-add` denylist enforcement, FQDN/target validation, denylist add/remove/reset |
| `trust.tests.ps1` | Host-side: `cwc trust`/`untrust`, trust state detection for `.env`/`.mcp.json`/`claude-sandbox.overlay.yml` |
| `settings-merge.tests.ps1` | Container: settings.json deep-merge of global + per-project overlay, project additions never mutate global |
| `harden.tests.ps1` | Container: watchdog re-applies removed blackhole, removes unauthorized routes, restores hosts file |

Container tests take ~5–15 seconds each (container startup dominates); host-only tests (`denylist`, `trust`) are ~1s each. Full suite is ~5–8 minutes with harden tests' 6s sleeps.

## Adding tests

Drop a new `*.tests.ps1` file in this directory; the runner auto-discovers them. Available helpers (from `lib/harness.ps1`):

- `Run-TestCase -Category <name> -Name <test> -Test { ... }` — wrap each assertion
- `Set-CwcConfig [-LockdownLan <bool>] [-AllowNets @(...)] [-ExtraHosts @{}] [-Mounts @{}] [-HostDenylist @(...)] [-HardenEnabled <bool>] [-TrustedFiles @{}]` — replace `~/.cwc/config.json` with a known state. Each call writes the full config; defaults are conservative (lockdown on, harden off, default Anthropic denylist).
- `Invoke-InContainer 'powershell-command' [-WorkDir <path>] [-Env @{}]` — run inside a one-shot container; defaults to the fixture workspace. Use this for tests that exercise entrypoint / container behaviour.
- `Invoke-CwcOnHost -Args @('firewall','host-add','...') [-WorkDir <path>]` — run a `cwc` subcommand on the host (no container start). Captures all PowerShell streams via `*>&1`. Use this for host-side commands like trust, denylist, harden config. Returns `@{ ExitCode = ...; Output = ... }`.
- `Should-Match`, `Should-NotMatch`, `Should-BeTrue`, `Should-Equal`, `Should-NotEqual` — throw on failure with helpful messages

## What this doesn't test

- **Adversarial prompts.** Whether claude tries to violate a boundary depends on prompts + model behaviour and isn't deterministic. Out of scope here (Layer 2 in the original plan).
- **Determined attackers inside the container.** Code running as Administrator can `Remove-NetRoute` and re-enable LAN access. The lockdown is speed-bump defense; tests assert the speed-bump exists, not that it's unbypassable.
- **Hostile-content public IPs.** Egress to public IPs isn't restricted by design; nothing to test.
