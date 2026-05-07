# Release process

How to cut a release of `claude-win-container`. Maintainer-facing — not relevant to end users.

## Branching strategy

| Branch | What CI does | What it's for |
| --- | --- | --- |
| `main` | nothing | Post-release state only. Updated solely via the auto-opened PR after a release lands. Never push directly. |
| `release/<semver>` | lint → test → build → smoke → push to Docker Hub (incl. `latest`) → GitHub release → auto-PR to `main` | The branch that *ships* a stable version. One commit per release; push triggers the full pipeline. |
| `preview/<anything>` | lint → test → build → smoke → push to Docker Hub (NO `latest`) → GitHub *pre-release* | End-to-end validation of the publish pipeline before cutting a real release. Same publishing flow as release, but doesn't claim `latest` and doesn't auto-PR to main. |
| Anything else (`feature/foo`, `dev`, etc.) | nothing | Keep work in flight here. Trigger CI by promoting to `preview/*` (validate) or `release/*` (ship). |

`workflow_dispatch` (the manual "Run workflow" button on the Actions UI) also exists. From a non-release/non-preview branch it builds + smoke-tests but never publishes — reserved for debugging.

### How preview differs from release

**Preview tags are SHA-suffixed and live in their own namespace; release tags are plain semver.** A `preview/0.1.1` branch and a later `release/0.1.1` branch produce **different** Docker tags and **different** GitHub releases — they don't collide, and any number of preview builds can ship for the same `x.y.z` without clobbering each other.

| | `preview/<version>` (push at commit `<sha>`) | `release/<version>` |
| --- | --- | --- |
| Effective version | `<version>.<sha-first-6>` (e.g. `0.1.1.d9cd72`) | `<version>` (e.g. `0.1.1`) |
| Docker tags pushed (SHA-pinned, preserved per build) | `:0.1.1.d9cd72`, `:0.1.1.d9cd72-ltsc2019`, `:0.1.1.d9cd72-ltsc2022` | `:0.1.1`, `:0.1.1-ltsc2019`, `:0.1.1-ltsc2022` |
| Docker moving pointer (overwritten each push) | `:preview`, `:preview-ltsc2019`, `:preview-ltsc2022` | `:latest`, `:latest-ltsc2019`, `:latest-ltsc2022` |
| GitHub release tag | `preview` (literal string; single moving release, upserted) | `v0.1.1` (one release per version, preserved) |
| Marked as Pre-release on GitHub | **yes** | no |
| Auto-PR to `main` | no | yes |

The asymmetry is deliberate:

- **Stable releases are immutable historical artifacts.** Once `v0.1.1` ships, that exact tag never changes. Each version gets its own GitHub release entry and `:<version>` Docker tag, both preserved.
- **Preview builds are unstable churn.** During QA you may push `preview/0.1.1` half a dozen times — each commit gets a SHA-pinned Docker tag (`:0.1.1.d9cd72`, `:0.1.1.4abc12`, ...) so testers can pin to an exact known build, but the GitHub release is a single moving target (literal tag `preview`, upserted via `softprops/action-gh-release@v2`) and the `:preview` Docker tag also moves. That keeps the install URL `releases/download/preview/install.ps1` stable while preview builds churn underneath.

Typical flow:

1. Push `preview/0.1.1` (commit `d9cd72ab...`) → CI builds + smoke-tests. Pushes `:0.1.1.d9cd72`/`-ltsc*` SHA-pinned tags. Updates `:preview`/`-ltsc*` to point at this build. Upserts the `preview` GitHub release: title `Preview 0.1.1.d9cd72`, marked pre-release, assets attached.
2. QA finds an issue, fix, push `preview/0.1.1` again at a new commit → same flow, new SHA-pinned tag (`:0.1.1.4abc12`), `:preview` and the GitHub release move forward. Old SHA-pinned tag stays on Docker Hub.
3. When ready, push `release/0.1.1` → CI publishes `:0.1.1`, `:0.1.1-ltsc*`, updates `:latest`/`-ltsc*`, creates a separate GitHub release `v0.1.1` (no pre-release flag), opens auto-PR to `main`. The `preview` release is unaffected — it still points at whatever the last preview build was, in case anyone is testing future-version previews.

Anyone running `:preview` or `:0.1.1.d9cd72`-pinned during step 2 doesn't get auto-promoted to the stable release — they have to opt in (pull `:0.1.1` or `:latest`).

## One-time setup

Before the first preview or release ever runs, you need two repository secrets in GitHub so the build workflow can push images to Docker Hub. Once set, they persist; you only redo this if the token is rotated or revoked.

### Step 1 — create a Docker Hub access token

1. Sign in at <https://hub.docker.com/>.
2. Click your username (top right) → **Account settings**.
3. Open the **Personal access tokens** tab → **Generate new token**.
4. Description: something like `github-actions-claude-win-container` so future-you knows what it's for.
5. Access permissions: **Read & Write**. (Delete isn't needed; we only push.)
6. Click **Generate**.
7. **Copy the token immediately**. Docker Hub shows it exactly once. Stash it in a password manager — you'll paste it into GitHub in the next step.

### Step 2 — add the username + token as GitHub secrets

1. Go to <https://github.com/vinylflamingo/claude-win-container/settings/secrets/actions>.
2. Click **New repository secret** and add:
   - Name: `DOCKERHUB_USERNAME`
   - Value: `fcostoya`
3. Click **New repository secret** again and add:
   - Name: `DOCKERHUB_TOKEN`
   - Value: (paste the token from Step 1)

That's it. The workflow already references both of these by name (`secrets.DOCKERHUB_USERNAME`, `secrets.DOCKERHUB_TOKEN`).

> `GITHUB_TOKEN` is **not** a secret you create. GitHub Actions provides it automatically for every workflow run — the release job uses it to create GitHub releases, and the `post-release-pr` job uses it to open the PR to `main`. Don't add it manually.

### Step 3 — repository workflow permissions

The `post-release-pr` job needs `pull-requests: write` on the auto-provided `GITHUB_TOKEN`. The job declares this in its YAML, but GitHub also gates it at the repo level:

1. Go to <https://github.com/vinylflamingo/claude-win-container/settings/actions>.
2. Under **Workflow permissions**, select **Read and write permissions**.
3. Tick **Allow GitHub Actions to create and approve pull requests**.
4. Save.

Without this, the auto-PR step will fail with a 403.

### Step 4 (recommended) — verify with a preview run

Push a `preview/*` branch and watch the workflow at <https://github.com/vinylflamingo/claude-win-container/actions>:

```powershell
git checkout -b preview/0.0.1
git push -u origin preview/0.0.1
```

Expected sequence (about 12–15 minutes):

```text
Classify branch        → green (kind=preview, version=0.0.1.<sha>)
Lint PowerShell        → green
Host-side tests        → green
Build (ltsc2019)       → green, including push (SHA-pinned + :preview, no :latest)
Build (ltsc2022)       → green, including push (SHA-pinned + :preview-ltsc2022, no :latest-ltsc2022)
Create GitHub release  → green (upserts the `preview` release as pre-release)
Open PR to main        → not run (gated on is_release, not just is_publishable)
```

After it finishes:

- <https://hub.docker.com/r/fcostoya/claude-win-container/tags> should show:
  - SHA-pinned tags `0.0.1.<sha>`, `0.0.1.<sha>-ltsc2019`, `0.0.1.<sha>-ltsc2022`
  - Moving tags `preview`, `preview-ltsc2019`, `preview-ltsc2022`
- <https://github.com/vinylflamingo/claude-win-container/releases> should show a yellow-badged release titled "Preview 0.0.1.<sha>" with the literal git tag `preview`.

Once verified, you can delete the preview branch and the SHA-pinned Docker tags by hand — they're disposable. The `:preview` tag and `preview` GitHub release will get overwritten by the next preview push (yours or someone else's), so they don't need cleanup.

## Cutting a release

```text
                         ┌── optional, but recommended ──┐
feature/foo  ──merge──→  preview/x.y.z  ──merge──→  release/x.y.z  ──auto-PR──→  main
                         (each push: :x.y.z.<sha> + moving :preview, single moving GitHub release)  (one-time: :x.y.z + :latest, vx.y.z GitHub release)  (no CI)
```

### Step 1 — finalise the CHANGELOG

In `CHANGELOG.md`:

1. Move whatever's under `## [Unreleased]` into a new versioned section: `## [1.2.3] - YYYY-MM-DD`.
2. Recreate an empty `## [Unreleased]` block above it for the next cycle.

The release workflow extracts the `## [1.2.3]` section verbatim and uses it as the GitHub release body. Whatever you write under that heading is what users see when they read the release on GitHub.

### Step 2 — create the release branch and push

```powershell
# From whatever branch holds the work to release (could be main, a preview
# branch, or a feature branch — CI doesn't care where you cut from):
git checkout -b release/1.2.3

# Commit the CHANGELOG update
git add CHANGELOG.md
git commit -m "Release v1.2.3"

# Push. This triggers the full release pipeline.
git push -u origin release/1.2.3
```

The workflow:

1. Classifies the branch (`release/1.2.3` → version `1.2.3`, kind `release`).
2. Lints, runs host-side tests.
3. Builds both `ltsc2019` and `ltsc2022` images, smoke-tests each.
4. Logs into Docker Hub with `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN`.
5. Pushes six tags: `1.2.3`, `1.2.3-ltsc2019`, `1.2.3-ltsc2022`, `latest`, `latest-ltsc2019`, `latest-ltsc2022`.
6. Creates a GitHub release with tag `v1.2.3` and body extracted from `CHANGELOG.md`.
7. Opens a PR from `release/1.2.3` → `main`.

Total wall-clock time: ~12–15 minutes (the Windows builds dominate).

### Step 3 — verify and merge the PR

After the workflow finishes, three things should exist:

1. <https://github.com/vinylflamingo/claude-win-container/releases/tag/v1.2.3> — the GitHub release.
2. <https://hub.docker.com/r/fcostoya/claude-win-container/tags> — the six new image tags.
3. <https://github.com/vinylflamingo/claude-win-container/pulls> — an open PR titled `Merge release/1.2.3 into main`.

Review the PR (the body has a checklist), merge it. After merging, you can safely delete the release branch.

### Hotfix flow

If something is broken on a released version and you need a patch:

1. Branch off the previous release tag: `git checkout -b release/1.2.4 v1.2.3`.
2. Cherry-pick / commit the fix.
3. Update `CHANGELOG.md` (new `## [1.2.4]` section).
4. Push. Same pipeline runs.

If you push to a `release/*` branch and the workflow fails partway through (say, the smoke test reveals a real issue), don't try to overwrite the same version — Docker Hub blocks tag mutations of immutable images. Bump to the next patch (`release/1.2.4`) and try again.

## Cutting a preview

Same flow as a release, just on a `preview/*` branch with the version number you intend to ship as stable:

```powershell
git checkout -b preview/1.2.3
# (commit whatever you want validated)
git push -u origin preview/1.2.3
```

The workflow appends the first 6 characters of the commit SHA to the version (so `preview/1.2.3` at commit `d9cd72ab...` becomes effective version `1.2.3.d9cd72`). It then:

1. Builds + smoke-tests both base images.
2. Pushes SHA-pinned Docker tags: `:1.2.3.d9cd72`, `:1.2.3.d9cd72-ltsc2019`, `:1.2.3.d9cd72-ltsc2022`. Each preview build gets its own pinned tag, preserved on Docker Hub.
3. Pushes the moving `:preview` / `:preview-ltsc2019` / `:preview-ltsc2022` tags so users can pull "the latest preview" without knowing the SHA.
4. Upserts the single `preview` GitHub release (literal tag string `preview`): title becomes `Preview 1.2.3.d9cd72`, marked pre-release, assets attached. Older preview release content gets replaced — only the most recent preview is "the" preview release at any given time.

Skips: `:latest` Docker tags (those are stable-only), and there's no auto-PR back to `main`.

**Multiple preview pushes are expected.** During QA you may iterate `preview/1.2.3` half a dozen times — each commit gets its own SHA-pinned tag (no clobber), and the moving pointers (`:preview`, the `preview` GitHub release) advance with each push. Testers who want to reproduce a specific build pull the SHA-pinned tag (`:1.2.3.d9cd72`); testers who want "whatever the team is currently testing" pull `:preview` or use `-Ref preview` for the install command.

**Ad-hoc preview names** (`preview/test-pipeline`, `preview/debug-foo`) still work — the workflow sanitises them for Docker tag rules — but the SHA gets appended too (`test-pipeline.d9cd72`), so they look ugly. Use them only for one-off pipeline debugging; the convention is plain `preview/<x.y.z>` matching the version you intend to ship.

## What the workflow does, step by step

The full pipeline lives in [`.github/workflows/build-and-release.yml`](../.github/workflows/build-and-release.yml). Six jobs:

| Job | Triggers when | What it does |
| --- | --- | --- |
| `classify` | every workflow run | Parses `GITHUB_REF_NAME` into `version`, `branch_kind`, `is_release`, `is_publishable` outputs. Validates that `release/*` branches use semver. Other jobs gate on these outputs. |
| `lint` | every run, after `classify` | `PSScriptAnalyzer` on all `.ps1`/`.psm1`/`.psd1` files. Errors block; warnings surface but pass. |
| `test-host` | every run, after `classify` | Runs `tests/run.ps1 -Filter 'denylist\|trust'` on a windows-latest runner. Host-only test subset, no Docker required. ~30s. |
| `build` (matrix × 2) | every run, after `lint` + `test-host` | `docker build` for `ltsc2019` + `ltsc2022`; smoke-tests each. On `is_publishable` (release or preview), pushes the version-tagged images. On `is_release` (release only), additionally pushes the `latest` aliases. |
| `release` | when `is_publishable`, after `build` | Extracts the matching CHANGELOG section, generates an image table + quickstart, creates the GitHub release with tag `v<semver>`, and uploads the launcher files as release assets (see below). For preview branches, marks the release as a pre-release and prepends a banner. |
| `post-release-pr` | when `is_release` (release only), after `release` | Opens a PR from the release branch to `main`. Idempotent — if a PR is already open for this branch, leaves it alone. |

### Release assets

The `release` job attaches four files as assets to every release (preview and stable alike):

- `install.ps1`
- `cwc.ps1`
- `docker-compose.yml`
- `project-overlay.example.yml` (uploaded flat — the in-repo path is `overlays/project-overlay.example.yml`)

These assets are what makes the install URLs work:

- **Stable** (default) — `https://github.com/<owner>/<repo>/releases/latest/download/install.ps1`. GitHub's `releases/latest` redirect resolves to the most recent **non-prerelease** release, so users running the standard install command always get the latest stable launcher; preview releases are automatically skipped.
- **Latest preview** — `https://github.com/<owner>/<repo>/releases/download/preview/install.ps1`. The literal tag `preview` is the moving GitHub pre-release that the workflow upserts on every preview push.
- **Pinned to a specific stable** — `https://github.com/<owner>/<repo>/releases/download/v1.2.3/install.ps1` (`-Ref v1.2.3`).

The release job uses different `tag_name` values for preview vs release: `preview` (literal) for previews, `v<version>` for releases. softprops upserts on the preview tag (so each preview push replaces the previous preview release content), and creates a new release per `v<version>` for stables (preserved historically).

If you change which files `install.ps1` downloads, update the `files:` list on the `softprops/action-gh-release@v2` step in the workflow to match. The asset namespace is flat (no directories) — if you add a file from a subdirectory, GitHub uploads it under just its basename.

Container-side tests (`network`, `settings-merge`, `harden`) are deliberately not in CI — they each spin up a real container, take ~20s each, and the matrix would multiply that. Run them locally with `.\tests\run.ps1 -Build` when iterating on `entrypoint.ps1`.

## Troubleshooting

**Workflow didn't trigger when I pushed.**
Check the branch name. The workflow only triggers on `release/**` and `preview/**`. Pushing to `feature/foo`, `main`, or `dev` does nothing — by design. Use `preview/<name>` to validate, `release/<semver>` to ship.

**`classify` failed with "release/* branches must use a semver suffix".**
You named the branch `release/oops` or `release/v1.0.0` (the leading `v` is wrong) or similar. Rename:

```powershell
git branch -m release/oops release/1.0.0
git push origin --delete release/oops
git push -u origin release/1.0.0
```

Note: this validation is only on `release/*`. Preview accepts any suffix.

**The Docker login step fails with "401 Unauthorized" or similar.**
The token has expired, been revoked, or `DOCKERHUB_USERNAME` doesn't match the repo owner. Re-run Step 1 + Step 2 of one-time setup. Tokens have configurable lifetimes; check the Docker Hub UI for what you set.

**The `Smoke test` step fails on `claude --version`.**
Most likely an upstream `@anthropic-ai/claude-code` change. The Dockerfile pulls the npm package by version tag (`latest` by default, pinnable via `--build-arg CLAUDE_CODE_VERSION=...`). Inspect the build logs — the `npm install -g` line should show what version actually got installed, and there may be a stack trace.

**The release body is empty or just the fallback "_No CHANGELOG entry for this version yet_".**
The CHANGELOG section header doesn't match the version. The extractor matches `## [VERSION]` exactly — `1.2.3`, not `v1.2.3`. If you used `## [v1.2.3] - ...` or `## [1.2.3](https://...)` the regex won't match. Stick to `## [VERSION] - YYYY-MM-DD`.

**The `release` step fails with "tag already exists".**
You're trying to re-release the same version. Tags are immutable on GitHub (and the matching Docker tag is immutable on Docker Hub). Bump to the next patch and re-cut: rename the branch to `release/1.2.4`, push.

**`post-release-pr` step fails with "no permissions" or 403.**
The repo's workflow permissions aren't set to allow PR creation. Fix per Step 3 of one-time setup (Repo Settings → Actions → General → Workflow permissions → Read and write + allow PR creation).

**`Lint` fails because PSScriptAnalyzer flagged something.**
Run it locally before pushing:

```powershell
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path . -Recurse -ExcludeRule PSAvoidUsingWriteHost
```

We exclude `PSAvoidUsingWriteHost` because Write-Host is the correct choice for a CLI tool's user-facing output. Other rules apply normally.

**`Host-side tests` fails on the windows-latest runner.**
The host-only suite is fast and stable, but if a test breaks, the runner uploads its log via the standard Actions output. Look for `[denylist]` or `[trust]` lines in the run output; the failure message includes the actual command output and the assertion that fired. Reproduce locally with `.\tests\run.ps1 -Filter 'denylist|trust'` — same command, same code.

**The `build` job times out.**
Windows container builds can be slow on cold runners (the base image pull is large). The workflow doesn't currently use BuildKit caching across runs; if this becomes a chronic issue, look into `cache-from`/`cache-to` with `type=gha` (note: cache support for Windows containers is more limited than Linux — verify before committing to it).

## Rotating the Docker Hub token

If a token leaks or is suspected of compromise:

1. <https://hub.docker.com/settings/security> — revoke the old token (the **Actions** column has a button per token).
2. Generate a new one (Step 1 of one-time setup).
3. Update the `DOCKERHUB_TOKEN` secret in GitHub: Settings → Secrets and variables → Actions → click `DOCKERHUB_TOKEN` → **Update**.
4. Push a `preview/*` branch and verify the workflow still publishes (login is gated on `is_publishable` so a preview push exercises it without claiming `latest`).

The username doesn't change; only the token. If the Docker Hub *account* changes (e.g., moving from `fcostoya` to a team account), update both `DOCKERHUB_USERNAME` and the `IMAGE_NAME` env var at the top of the workflow (and grep the rest of the repo for hardcoded Docker references — the `cwc.ps1` default, `docker-compose.yml` fallback, `README.md` examples, etc.).
