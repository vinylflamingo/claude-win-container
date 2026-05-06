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

    # Project B should NOT see the marker (separate slug → separate state dir)
    $outB = Invoke-InContainer 'Test-Path C:\claude-data\test-marker.txt' -WorkDir $projB
    Should-Match $outB 'False' -Because 'project B should not see project A''s claude-data'

    # Project A should still have it on a fresh container
    $outA = Invoke-InContainer 'Get-Content C:\claude-data\test-marker.txt -ErrorAction SilentlyContinue' -WorkDir $projA
    Should-Match $outA $marker -Because 'project A''s state should persist across sessions'
}

Run-TestCase -Category auth -Name 'auth-managed files propagate across projects' -Test {
    Set-CwcConfig

    $projA = Join-Path (Split-Path $script:fixtures.workspace -Parent) 'proj-a'
    $projB = Join-Path (Split-Path $script:fixtures.workspace -Parent) 'proj-b'
    foreach ($p in @($projA, $projB)) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        if (-not (Test-Path (Join-Path $p '.git'))) { git init $p *> $null }
    }

    # Auth-managed files live at C:\claude-data\<file> (CLAUDE_CONFIG_DIR). The entrypoint
    # copies auth-relevant files (settings.json among them) back to C:\claude-auth\ on exit
    # so they're shared. Writing directly to C:\claude-auth during a session is clobbered
    # by that exit-time copy — write through claude-data instead, the way Claude itself does.
    $marker = "auth-marker-$(Get-Random)"
    $null = Invoke-InContainer "Set-Content C:\claude-data\settings.json -Value $marker" -WorkDir $projA

    # Project B starts fresh: entrypoint copies C:\claude-auth\settings.json (now containing
    # A's marker) into B's per-project C:\claude-data\settings.json. So B sees A's marker.
    $outB = Invoke-InContainer 'Get-Content C:\claude-data\settings.json -ErrorAction SilentlyContinue' -WorkDir $projB
    Should-Match $outB $marker -Because 'global-class files written from project A should propagate to project B via the auth bind'
}
