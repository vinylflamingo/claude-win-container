# Trust system tests.
# The trust system tracks SHA-256 of three workspace policy files:
# claude-sandbox.overlay.yml, .env, .mcp.json. When any of these change without
# explicit `cwc trust` ack, cwc refuses to launch (or prompts in a real TTY).
#
# These tests run on the HOST — they exercise cwc.ps1's pre-launch behaviour
# without needing the container to actually start.

# Helper: ensure a fresh per-test state — empty workspace files, no trust state.
function Reset-TrustFixture {
    foreach ($f in @('.env', '.mcp.json', 'claude-sandbox.overlay.yml')) {
        $p = Join-Path $script:fixtures.workspace $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    Set-CwcConfig  # default config — empty trusted_files map
}

Run-TestCase -Category trust -Name 'no tracked files - launches without prompt' -Test {
    Reset-TrustFixture
    # No tracked files in the workspace; trust check should pass silently.
    $r = Invoke-CwcOnHost -Args @('trust','list') -WorkDir $script:fixtures.workspace
    Should-Equal $r.ExitCode 0
    Should-Match $r.Output 'absent' -Because 'all tracked files should show as absent'
}

Run-TestCase -Category trust -Name 'untrusted .env reports NEW state' -Test {
    Reset-TrustFixture
    'CLAUDE_FOO=bar' | Set-Content -LiteralPath (Join-Path $script:fixtures.workspace '.env')
    $r = Invoke-CwcOnHost -Args @('trust','list') -WorkDir $script:fixtures.workspace
    Should-Equal $r.ExitCode 0
    Should-Match $r.Output 'NEW.+\.env' -Because '.env should show as NEW (untrusted)'
}

Run-TestCase -Category trust -Name 'cwc trust records hashes; trust list shows trusted' -Test {
    Reset-TrustFixture
    'CLAUDE_FOO=bar' | Set-Content -LiteralPath (Join-Path $script:fixtures.workspace '.env')
    $r1 = Invoke-CwcOnHost -Args @('trust') -WorkDir $script:fixtures.workspace
    Should-Equal $r1.ExitCode 0
    Should-Match $r1.Output 'Trusted current state'
    $r2 = Invoke-CwcOnHost -Args @('trust','list') -WorkDir $script:fixtures.workspace
    Should-Match $r2.Output 'trusted.+\.env' -Because 'after trust, .env should show as trusted'
}

Run-TestCase -Category trust -Name 'modifying .env after trust shows MODIFIED' -Test {
    Reset-TrustFixture
    $envPath = Join-Path $script:fixtures.workspace '.env'
    'CLAUDE_FOO=v1' | Set-Content -LiteralPath $envPath
    Invoke-CwcOnHost -Args @('trust') -WorkDir $script:fixtures.workspace | Out-Null
    'CLAUDE_FOO=v2' | Set-Content -LiteralPath $envPath
    $r = Invoke-CwcOnHost -Args @('trust','list') -WorkDir $script:fixtures.workspace
    Should-Match $r.Output 'MODIFIED.+\.env'
}

Run-TestCase -Category trust -Name 'cwc untrust removes trust state' -Test {
    Reset-TrustFixture
    'CLAUDE_FOO=bar' | Set-Content -LiteralPath (Join-Path $script:fixtures.workspace '.env')
    Invoke-CwcOnHost -Args @('trust') -WorkDir $script:fixtures.workspace | Out-Null
    $r1 = Invoke-CwcOnHost -Args @('untrust') -WorkDir $script:fixtures.workspace
    Should-Equal $r1.ExitCode 0
    Should-Match $r1.Output 'Removed trust'
    $r2 = Invoke-CwcOnHost -Args @('trust','list') -WorkDir $script:fixtures.workspace
    Should-Match $r2.Output 'NEW.+\.env' -Because 'after untrust, .env should be untrusted again'
}

Run-TestCase -Category trust -Name 'tracked overlay is detected' -Test {
    Reset-TrustFixture
    'services: { claude-code: {} }' | Set-Content -LiteralPath (Join-Path $script:fixtures.workspace 'claude-sandbox.overlay.yml')
    $r = Invoke-CwcOnHost -Args @('trust','list') -WorkDir $script:fixtures.workspace
    Should-Match $r.Output 'NEW.+claude-sandbox\.overlay\.yml'
}

Run-TestCase -Category trust -Name 'tracked .mcp.json is detected' -Test {
    Reset-TrustFixture
    '{}' | Set-Content -LiteralPath (Join-Path $script:fixtures.workspace '.mcp.json')
    $r = Invoke-CwcOnHost -Args @('trust','list') -WorkDir $script:fixtures.workspace
    Should-Match $r.Output 'NEW.+\.mcp\.json'
}
