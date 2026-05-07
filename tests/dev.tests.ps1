# cwc dev tests -- host-side. Exercises the management subcommands and flag
# persistence; doesn't actually launch a :dev container or build the image
# (that requires Docker and 5+ minutes -- covered by the full-suite -Build path).
#
# The test runner snapshots ~/.cwc/ before each suite, so dev.json starts fresh.

# These tests need to invoke cwc from the actual clone (Test-CwcInClone returns
# true only when Dockerfile + docker-compose.yml sit next to cwc.ps1). The runner's
# cwc alias points at the repo's cwc.ps1, so we need -WorkDir to NOT be the
# fixture workspace (which is a temp dir without those files).
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

Run-TestCase -Category dev -Name 'flag list shows defaults' -Test {
    $r = Invoke-CwcOnHost -Args @('dev','flag','list') -WorkDir $script:repoRoot
    Should-Equal $r.ExitCode 0
    Should-Match $r.Output 'live_entrypoint_mount = off'
    Should-Match $r.Output 'default: off'
}

Run-TestCase -Category dev -Name 'flag set persists to dev.json' -Test {
    $r1 = Invoke-CwcOnHost -Args @('dev','flag','set','live_entrypoint_mount','on') -WorkDir $script:repoRoot
    Should-Equal $r1.ExitCode 0
    Should-Match $r1.Output 'Set live_entrypoint_mount = on'

    $devJson = Join-Path $env:USERPROFILE '.cwc\dev.json'
    Should-BeTrue (Test-Path $devJson) -Because 'dev.json should be created'
    $parsed = Get-Content $devJson -Raw | ConvertFrom-Json
    Should-Equal ([bool]$parsed.flags.live_entrypoint_mount) $true

    $r2 = Invoke-CwcOnHost -Args @('dev','flag','list') -WorkDir $script:repoRoot
    Should-Match $r2.Output 'live_entrypoint_mount = on'
}

Run-TestCase -Category dev -Name 'flag set off persists' -Test {
    Invoke-CwcOnHost -Args @('dev','flag','set','live_entrypoint_mount','on') -WorkDir $script:repoRoot | Out-Null
    $r = Invoke-CwcOnHost -Args @('dev','flag','set','live_entrypoint_mount','off') -WorkDir $script:repoRoot
    Should-Equal $r.ExitCode 0
    Should-Match $r.Output 'Set live_entrypoint_mount = off'
}

Run-TestCase -Category dev -Name 'flag unset resets to default' -Test {
    Invoke-CwcOnHost -Args @('dev','flag','set','live_entrypoint_mount','on') -WorkDir $script:repoRoot | Out-Null
    $r = Invoke-CwcOnHost -Args @('dev','flag','unset','live_entrypoint_mount') -WorkDir $script:repoRoot
    Should-Equal $r.ExitCode 0
    Should-Match $r.Output 'Reset live_entrypoint_mount'
    $list = Invoke-CwcOnHost -Args @('dev','flag','list') -WorkDir $script:repoRoot
    Should-Match $list.Output 'live_entrypoint_mount = off'
}

Run-TestCase -Category dev -Name 'flag set rejects unknown flag' -Test {
    $r = Invoke-CwcOnHost -Args @('dev','flag','set','no_such_flag','on') -WorkDir $script:repoRoot
    Should-NotEqual $r.ExitCode 0
    Should-Match $r.Output 'Unknown flag'
}

Run-TestCase -Category dev -Name 'flag set rejects bad value' -Test {
    $r = Invoke-CwcOnHost -Args @('dev','flag','set','live_entrypoint_mount','maybe') -WorkDir $script:repoRoot
    Should-NotEqual $r.ExitCode 0
    Should-Match $r.Output 'on\|off'
}

Run-TestCase -Category dev -Name 'status reports clone path and flags' -Test {
    $r = Invoke-CwcOnHost -Args @('dev','status') -WorkDir $script:repoRoot
    Should-Equal $r.ExitCode 0
    Should-Match $r.Output 'cwc dev status'
    Should-Match $r.Output 'image      : fcostoya/claude-win-container:dev'
    Should-Match $r.Output 'clone      :'
    Should-Match $r.Output 'live_entrypoint_mount'
}

Run-TestCase -Category dev -Name 'host-side subcommand wrapping is rejected' -Test {
    foreach ($sub in @('firewall','mount','trust','harden','setup')) {
        $r = Invoke-CwcOnHost -Args @('dev',$sub,'list') -WorkDir $script:repoRoot
        Should-NotEqual $r.ExitCode 0 -Because "cwc dev $sub should be rejected"
        Should-Match $r.Output "no 'dev' wrapper needed"
    }
}
