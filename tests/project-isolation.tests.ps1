# Project-isolation tests -- verify the per-project config split actually keeps
# projects separate. Each project gets its own ~/.cwc/projects/<slug>/config.json;
# a host service exposed in project A must NOT be visible from project B.
#
# Host-side; no container start required.

# Helper: create a fresh fixture project dir under the suite's fixtures root and
# git-init it so cwc's project-root heuristic accepts it.
function New-FixtureProject {
    param([Parameter(Mandatory)] [string]$Name)
    $dir = Join-Path $script:fixtures.workspace "..\proj-$Name"
    $dir = (New-Item -ItemType Directory -Force -Path $dir).FullName
    git init $dir *> $null
    return $dir
}

Run-TestCase -Category project-isolation -Name 'two projects keep separate extra_hosts' -Test {
    $projA = New-FixtureProject -Name 'a'
    $projB = New-FixtureProject -Name 'b'

    Set-CwcConfig -ProjectDir $projA -ExtraHosts @{
        'host' = @{ target = 'host-gateway'; ports = @(3000) }
    }
    Set-CwcConfig -ProjectDir $projB
    # No extra_hosts in B.

    $rA = Invoke-CwcOnHost -Args @('firewall','host-list') -WorkDir $projA
    Should-Match $rA.Output 'host -> host-gateway' -Because 'project A should see its own mapping'
    Should-Match $rA.Output 'ports=3000' -Because 'project A should see port 3000'

    $rB = Invoke-CwcOnHost -Args @('firewall','host-list') -WorkDir $projB
    Should-Match $rB.Output '\(no host mappings\)' -Because 'project B should not see project A''s mappings'
    Should-NotMatch $rB.Output 'ports=3000'
}

Run-TestCase -Category project-isolation -Name 'firewall allow in A does not leak to B' -Test {
    $projA = New-FixtureProject -Name 'a-allow'
    $projB = New-FixtureProject -Name 'b-allow'

    Set-CwcConfig -ProjectDir $projA -AllowNets @('192.168.50.0/24')
    Set-CwcConfig -ProjectDir $projB
    # No allow_nets in B.

    $rA = Invoke-CwcOnHost -Args @('firewall','list') -WorkDir $projA
    Should-Match $rA.Output '192\.168\.50\.0/24' -Because 'project A should see its allow'

    $rB = Invoke-CwcOnHost -Args @('firewall','list') -WorkDir $projB
    Should-NotMatch $rB.Output '192\.168\.50\.0/24' -Because 'project B should not see project A''s allow'
    Should-Match $rB.Output 'Allow-list   : \(none\)'
}

Run-TestCase -Category project-isolation -Name 'harden enable in A does not affect B' -Test {
    $projA = New-FixtureProject -Name 'a-harden'
    $projB = New-FixtureProject -Name 'b-harden'

    Set-CwcConfig -ProjectDir $projA -HardenEnabled $true
    Set-CwcConfig -ProjectDir $projB -HardenEnabled $false

    $rA = Invoke-CwcOnHost -Args @('harden','status') -WorkDir $projA
    Should-Match $rA.Output 'Harden : ENABLED' -Because 'project A should be hardened'

    $rB = Invoke-CwcOnHost -Args @('harden','status') -WorkDir $projB
    Should-Match $rB.Output 'Harden : disabled' -Because 'project B should not inherit project A''s harden'
}

Run-TestCase -Category project-isolation -Name 'denylist is global; both projects see it' -Test {
    $projA = New-FixtureProject -Name 'a-deny'
    $projB = New-FixtureProject -Name 'b-deny'

    Set-CwcConfig -ProjectDir $projA
    Set-CwcConfig -ProjectDir $projB
    # Both projects share the same global denylist (added once below).

    Invoke-CwcOnHost -Args @('firewall','denylist','add','shared-deny.example.com') | Out-Null

    foreach ($p in @($projA, $projB)) {
        $r = Invoke-CwcOnHost -Args @('firewall','denylist','list') -WorkDir $p
        Should-Match $r.Output 'shared-deny\.example\.com' -Because "denylist add must be visible from $p (denylist is global)"
    }
}
