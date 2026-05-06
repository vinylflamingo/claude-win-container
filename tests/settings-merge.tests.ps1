# Settings deep-merge tests.
# Phase 3 of the security plan moved settings.json from "whole-file global" to
# "global baseline + per-project overlay, deep-merged on entry, delta-on-exit."
# These tests verify:
#   - Global settings flow into the container's settings.json
#   - A per-project overlay overrides specific keys (project wins)
#   - Changes made in the container are written to the per-project overlay only,
#     never to the global file (closes the cross-project agent persistence vector)

Run-TestCase -Category settings -Name 'global settings.json flows into container' -Test {
    Set-CwcConfig
    # Write a global settings.json before the container starts.
    $authDir = Join-Path $env:USERPROFILE '.claude-win-container\auth'
    if (-not (Test-Path $authDir)) { New-Item -ItemType Directory -Force -Path $authDir | Out-Null }
    $globalSettingsPath = Join-Path $authDir 'settings.json'
    '{"theme":"global-dark","telemetry":false}' | Set-Content -LiteralPath $globalSettingsPath

    $out = Invoke-InContainer 'Get-Content C:\claude-data\settings.json -Raw'
    Should-Match $out '"theme"\s*:\s*"global-dark"' -Because 'global settings should be present in container'
    Should-Match $out '"telemetry"\s*:\s*false'

    Remove-Item -LiteralPath $globalSettingsPath -Force -ErrorAction SilentlyContinue
}

Run-TestCase -Category settings -Name 'project overlay overrides global key' -Test {
    Set-CwcConfig
    $authDir = Join-Path $env:USERPROFILE '.claude-win-container\auth'
    if (-not (Test-Path $authDir)) { New-Item -ItemType Directory -Force -Path $authDir | Out-Null }
    '{"theme":"global-dark"}' | Set-Content -LiteralPath (Join-Path $authDir 'settings.json')

    # Compute project slug to find its config dir on the host
    $abs = (Resolve-Path $script:fixtures.workspace).Path.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($abs)
    $hash = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes)
    $hex = [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    $base = (Split-Path -Leaf $abs) -replace '[^a-z0-9._-]','-'
    $slug = "$base-$($hex.Substring(0,12))"
    $projCfgDir = Join-Path $env:USERPROFILE ".claude-win-container\projects\$slug\config"
    if (-not (Test-Path $projCfgDir)) { New-Item -ItemType Directory -Force -Path $projCfgDir | Out-Null }
    '{"theme":"project-light"}' | Set-Content -LiteralPath (Join-Path $projCfgDir 'settings-project.json')

    $out = Invoke-InContainer 'Get-Content C:\claude-data\settings.json -Raw'
    Should-Match $out '"theme"\s*:\s*"project-light"' -Because 'project overlay must win on key conflict'
}

Run-TestCase -Category settings -Name 'session changes go to per-project overlay, not global' -Test {
    Set-CwcConfig
    $authDir = Join-Path $env:USERPROFILE '.claude-win-container\auth'
    if (-not (Test-Path $authDir)) { New-Item -ItemType Directory -Force -Path $authDir | Out-Null }
    $globalSettingsPath = Join-Path $authDir 'settings.json'
    '{"theme":"global-dark"}' | Set-Content -LiteralPath $globalSettingsPath
    $globalBefore = Get-Content -LiteralPath $globalSettingsPath -Raw

    # Wipe any leftover overlay from prior tests so this test's expectation is clean.
    $abs = (Resolve-Path $script:fixtures.workspace).Path.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($abs)
    $hash = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes)
    $hex = [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    $base = (Split-Path -Leaf $abs) -replace '[^a-z0-9._-]','-'
    $slug = "$base-$($hex.Substring(0,12))"
    $overlayPath = Join-Path $env:USERPROFILE ".claude-win-container\projects\$slug\config\settings-project.json"
    if (Test-Path -LiteralPath $overlayPath) { Remove-Item -LiteralPath $overlayPath -Force }

    # Stage the "agent edit" as a file in the workspace bind mount, then have the
    # container Copy-Item it onto the merged settings.json. This bypasses all the
    # command-line quoting hazards of embedding JSON in a -Command string --
    # literal double quotes inside the JSON would otherwise get eaten by some
    # layer of the PS -> docker -> PS argv pipeline.
    $stagePath = Join-Path $script:fixtures.workspace 'agent-edit-settings.json'
    '{"theme":"global-dark","mcpServers":{"evil":{"command":"x"}}}' | Set-Content -LiteralPath $stagePath -NoNewline

    Invoke-InContainer 'Copy-Item C:\workspace\agent-edit-settings.json C:\claude-data\settings.json -Force' | Out-Null

    # Cleanup the staging file before assertions so it doesn't pollute later tests.
    if (Test-Path -LiteralPath $stagePath) { Remove-Item -LiteralPath $stagePath -Force }

    # Global must be unchanged.
    $globalAfter = Get-Content -LiteralPath $globalSettingsPath -Raw
    Should-Equal $globalAfter $globalBefore -Because 'global settings.json must NOT be mutated by sessions'

    # Per-project overlay should now hold the agent-added key.
    Should-BeTrue (Test-Path -LiteralPath $overlayPath) 'overlay file must exist after agent edit'
    $overlay = Get-Content -LiteralPath $overlayPath -Raw
    Should-Match $overlay 'evil' -Because 'agent additions must land in project overlay'
}
