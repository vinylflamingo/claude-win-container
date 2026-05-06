# claude-win-container

[![Build and release](https://github.com/vinylflamingo/claude-win-container/actions/workflows/build-and-release.yml/badge.svg)](https://github.com/vinylflamingo/claude-win-container/actions/workflows/build-and-release.yml)
[![Docker Hub](https://img.shields.io/docker/pulls/vinylflamingo/claude-win-container?label=docker%20pulls)](https://hub.docker.com/r/vinylflamingo/claude-win-container)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

A reusable Windows container for running [Claude Code](https://github.com/anthropics/claude-code) in a sandbox. One image, one launcher, used from any project on the host.

## Quickstart

```powershell
irm https://raw.githubusercontent.com/vinylflamingo/claude-win-container/main/install.ps1 | iex
```

The installer is interactive: it walks you through a security primer and a four-question firewall wizard (LAN subnets, host services like Traefik, custom FQDN -> IP mappings) before saving the config. Skip the wizard with `-SkipFirewallSetup` and configure later via `cwc firewall ...`.

Then open a new PowerShell, `cd` into any project, and run `cwc`. First run pulls the image (~6 GB) from Docker Hub.

```powershell
cd C:\Users\you\Projects\my-app
cwc                       # first run: pulls image, then launches `claude`
```

The installer drops the launcher into `%USERPROFILE%\.cwc\` and adds a `cwc` alias to your `$PROFILE`. Idempotent — safe to re-run.

## Pre-requisites

- Windows 10 / 11 / Server 2019+ with **Docker Desktop in Windows-containers mode**.
- PowerShell 5.1+ (ships with Windows).
- Hyper-V isolation supported on the host (default on Windows 10/11 Pro+).

## Usage

```powershell
cwc                       # runs `claude` inside the container
cwc help                  # full usage (also -Help / -h)
cwc powershell            # drops to a PowerShell prompt inside the container
cwc mcp list              # shorthand for `cwc claude mcp list`
cwc mcp add <name> -- <cmd> [args...]
cwc -Pull                 # docker pull latest image, then launch
cwc -Build                # build image from local Dockerfile (requires repo clone)
cwc -Force                # bypass the project-root heuristic
cwc -- --resume           # pass remaining args through to claude
```

**MCP servers** are configured per-project via `.mcp.json` at the project root. Copy [`examples/mcp.example.json`](./examples/mcp.example.json) as a starting point, or use `cwc mcp add` to scaffold entries. Any `${KEY}` referenced in `.mcp.json` is auto-forwarded from your project's `.env`. See [docs/per-project-setup.md](./docs/per-project-setup.md#starter-mcpjson) for the walkthrough.

Pin a specific version:

```powershell
$env:CWC_IMAGE = 'vinylflamingo/claude-win-container:1.0.0'
cwc
```

Or set it permanently in `$PROFILE` alongside the alias.

## Building from source

```powershell
git clone https://github.com/vinylflamingo/claude-win-container
cd claude-win-container
docker compose build              # ~5-10 min for first build
& .\cwc.ps1 -Build                # rebuild + launch
```

## Releases

Tag-driven semver. Pushing `v1.2.3` triggers a build that publishes:

- `vinylflamingo/claude-win-container:1.2.3-ltsc2019`
- `vinylflamingo/claude-win-container:1.2.3-ltsc2022`
- `vinylflamingo/claude-win-container:1.2.3` (= ltsc2019, max compat)
- `vinylflamingo/claude-win-container:latest` (= latest version, ltsc2019)
- `vinylflamingo/claude-win-container:latest-ltsc2019`
- `vinylflamingo/claude-win-container:latest-ltsc2022`

…and creates a GitHub release. See [Releases](https://github.com/vinylflamingo/claude-win-container/releases).

## License

MIT — see [LICENSE](./LICENSE).
