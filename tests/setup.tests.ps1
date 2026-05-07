# cwc setup tests -- verify the per-project setup wizard's behavior.
# Most of the wizard requires interactive input, so these tests focus on:
#   - the "no config + non-interactive launch" failure path
#   - the "subcommand with no config" failure path (Get-RequiredCwcProjectConfig)
#   - the explicit `cwc setup` requires interactive
#
# A real wizard walkthrough requires terminal piping that's awkward in CI; an
# integration test for that lives in tests/integration/ if/when added.
#
# Host-side; no container start required.

function New-FixtureProject {
    param([Parameter(Mandatory)] [string]$Name)
    $dir = Join-Path $script:fixtures.workspace "..\setup-$Name"
    $dir = (New-Item -ItemType Directory -Force -Path $dir).FullName
    git init $dir *> $null
    return $dir
}

Run-TestCase -Category setup -Name 'cwc firewall list refuses with no project config' -Test {
    $proj = New-FixtureProject -Name 'no-config'
    # Write only the global config, no per-project config for $proj.
    $globalPath = Join-Path $env:USERPROFILE '.cwc\config.json'
    $globalDir  = Split-Path -Parent $globalPath
    if (-not (Test-Path $globalDir)) { New-Item -ItemType Directory -Force -Path $globalDir | Out-Null }
    @{
        host_denylist = @('*.anthropic.com')
        defaults      = @{ lockdown_lan = $true; harden_enabled = $false }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $globalPath
    # Make sure no project config exists for this fixture.
    $slug = Get-CwcSlugForTest $proj
    $projCfgPath = Join-Path $env:USERPROFILE ".cwc\projects\$slug\config.json"
    if (Test-Path $projCfgPath) { Remove-Item -Force $projCfgPath }

    $r = Invoke-CwcOnHost -Args @('firewall','list') -WorkDir $proj
    Should-NotEqual $r.ExitCode 0 -Because 'subcommand should refuse without project config'
    Should-Match $r.Output 'No cwc config for this project'
    Should-Match $r.Output "Run 'cwc setup'"
}

Run-TestCase -Category setup -Name 'cwc mount add refuses with no project config' -Test {
    $proj = New-FixtureProject -Name 'mount-no-config'
    # Reuse the global config from the previous test; ensure no project config.
    $slug = Get-CwcSlugForTest $proj
    $projCfgPath = Join-Path $env:USERPROFILE ".cwc\projects\$slug\config.json"
    if (Test-Path $projCfgPath) { Remove-Item -Force $projCfgPath }

    $r = Invoke-CwcOnHost -Args @('mount','add','vault','C:\fake') -WorkDir $proj
    Should-NotEqual $r.ExitCode 0
    Should-Match $r.Output 'No cwc config for this project'
}

Run-TestCase -Category setup -Name 'denylist subcommands work without project config' -Test {
    $proj = New-FixtureProject -Name 'deny-no-config'
    $slug = Get-CwcSlugForTest $proj
    $projCfgPath = Join-Path $env:USERPROFILE ".cwc\projects\$slug\config.json"
    if (Test-Path $projCfgPath) { Remove-Item -Force $projCfgPath }

    # Denylist is global, so it should be usable even before `cwc setup`.
    $r = Invoke-CwcOnHost -Args @('firewall','denylist','list') -WorkDir $proj
    Should-Equal $r.ExitCode 0 -Because 'denylist list is global, not per-project'
    Should-Match $r.Output 'Host denylist'
}
