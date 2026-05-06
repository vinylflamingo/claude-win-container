# Cross-project state isolation.
# Verifies that two different project directories get separate slugs and don't share
# CLAUDE_CONFIG_DIR contents (memory, sessions, etc.).

Run-TestCase -Category auth -Name 'cross-project state is isolated' -Test {
    Set-CwcConfig

    # Two ad-hoc fixture project dirs (each a separate workspace from the runner's POV)
    $projA = Join-Path (Split-Path $script:fixtures.workspace -Parent) 'proj-a'
    $projB = Join-Path (Split-Path $script:fixtures.workspace -Parent) 'proj-b'
    foreach ($p in @($projA, $projB)) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        # Make each look like a project root so cwc's heuristic accepts it
        if (-not (Test-Path (Join-Path $p '.git'))) { git init $p *> $null }
    }

    $marker = "marker-$(Get-Random)"
    # Drop the marker into project A's claude-data
    $null = Invoke-InContainer "Set-Content C:\claude-data\test-marker.txt -Value $marker" -WorkDir $projA

    # Project B should NOT see the marker (separate slug -> separate state dir)
    $outB = Invoke-InContainer 'Test-Path C:\claude-data\test-marker.txt' -WorkDir $projB
    Should-Match $outB 'False' -Because 'project B should not see project A''s claude-data'

    # Project A should still have it on a fresh container
    $outA = Invoke-InContainer 'Get-Content C:\claude-data\test-marker.txt -ErrorAction SilentlyContinue' -WorkDir $projA
    Should-Match $outA $marker -Because 'project A''s state should persist across sessions'
}

Run-TestCase -Category auth -Name 'whole-file global (.credentials.json) propagates across projects' -Test {
    Set-CwcConfig

    $projA = Join-Path (Split-Path $script:fixtures.workspace -Parent) 'proj-a'
    $projB = Join-Path (Split-Path $script:fixtures.workspace -Parent) 'proj-b'
    foreach ($p in @($projA, $projB)) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        if (-not (Test-Path (Join-Path $p '.git'))) { git init $p *> $null }
    }

    # Phase 3 narrowed the auth bind: only .credentials.json and mcp-needs-auth-cache.json
    # are now whole-file global. settings.json is per-project (deep-merged with a global
    # baseline at entry, delta-on-exit). Writing through claude-data is the path Claude
    # itself uses; the entrypoint copies it back to claude-auth on exit.
    $marker = "creds-marker-$(Get-Random)"
    $null = Invoke-InContainer "Set-Content C:\claude-data\.credentials.json -Value '$marker'" -WorkDir $projA

    $outB = Invoke-InContainer 'Get-Content C:\claude-data\.credentials.json -ErrorAction SilentlyContinue' -WorkDir $projB
    Should-Match $outB $marker -Because '.credentials.json is whole-file global and must propagate'
}

Run-TestCase -Category auth -Name 'settings.json changes do NOT cross projects' -Test {
    Set-CwcConfig

    $projA = Join-Path (Split-Path $script:fixtures.workspace -Parent) 'proj-a'
    $projB = Join-Path (Split-Path $script:fixtures.workspace -Parent) 'proj-b'
    foreach ($p in @($projA, $projB)) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        if (-not (Test-Path (Join-Path $p '.git'))) { git init $p *> $null }
    }

    # Closes the cross-project agent persistence vector -- see docs/security.md, Phase 3.
    $marker = "settings-marker-$(Get-Random)"
    $cmdA = '$o = @{theme = "x"; agentMarker = "' + $marker + '"}; ' +
            'Set-Content -LiteralPath C:\claude-data\settings.json -Value ($o | ConvertTo-Json)'
    $null = Invoke-InContainer $cmdA -WorkDir $projA

    $outB = Invoke-InContainer 'Get-Content C:\claude-data\settings.json -ErrorAction SilentlyContinue' -WorkDir $projB
    Should-NotMatch $outB $marker -Because 'settings.json is per-project; agent edits in A must NOT appear in B'
}
