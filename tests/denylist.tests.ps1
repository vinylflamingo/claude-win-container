# Denylist tests — host-side checks; no container start required.
# Verifies that 'cwc firewall host-add' refuses denylisted FQDNs at config-write
# time, and that 'cwc firewall denylist add/remove' round-trips correctly.

Run-TestCase -Category denylist -Name 'host-add refuses default denylist FQDN' -Test {
    Set-CwcConfig
    $r = Invoke-CwcOnHost -Args @('firewall','host-add','api.anthropic.com')
    Should-NotEqual $r.ExitCode 0 -Because 'host-add to api.anthropic.com must be refused'
    Should-Match $r.Output 'Refused' -Because 'rejection message expected'
    Should-Match $r.Output 'denylist' -Because 'message should mention the denylist'
}

Run-TestCase -Category denylist -Name 'host-add refuses default denylist wildcard match' -Test {
    Set-CwcConfig
    $r = Invoke-CwcOnHost -Args @('firewall','host-add','foo.claude.ai')
    Should-NotEqual $r.ExitCode 0 -Because 'foo.claude.ai matches *.claude.ai default'
    Should-Match $r.Output 'Refused'
}

Run-TestCase -Category denylist -Name 'host-add allows non-denylisted FQDN' -Test {
    Set-CwcConfig
    $r = Invoke-CwcOnHost -Args @('firewall','host-add','traefik.local','host-gateway','443')
    Should-Equal $r.ExitCode 0 -Because 'unrelated FQDN should be accepted'
    Should-Match $r.Output 'Mapped'
    # Cleanup: remove the entry we just added so the test is idempotent.
    Invoke-CwcOnHost -Args @('firewall','host-remove','traefik.local') | Out-Null
}

Run-TestCase -Category denylist -Name 'denylist add then host-add refuses' -Test {
    Set-CwcConfig
    $r1 = Invoke-CwcOnHost -Args @('firewall','denylist','add','custom-deny.example.com')
    Should-Equal $r1.ExitCode 0
    $r2 = Invoke-CwcOnHost -Args @('firewall','host-add','custom-deny.example.com')
    Should-NotEqual $r2.ExitCode 0 -Because 'custom denylist entry should refuse host-add'
    Should-Match $r2.Output 'Refused'
}

Run-TestCase -Category denylist -Name 'denylist reset restores defaults only' -Test {
    Set-CwcConfig
    Invoke-CwcOnHost -Args @('firewall','denylist','add','custom-x.example.com') | Out-Null
    Invoke-CwcOnHost -Args @('firewall','denylist','reset') | Out-Null
    $r = Invoke-CwcOnHost -Args @('firewall','denylist','list')
    Should-Match $r.Output '\*\.anthropic\.com' -Because 'defaults must be present after reset'
    Should-NotMatch $r.Output 'custom-x\.example\.com' -Because 'custom entry should be gone after reset'
}

Run-TestCase -Category denylist -Name 'host-add validates malformed FQDN' -Test {
    Set-CwcConfig
    # Double-dot is a definitively invalid FQDN that the regex rejects (uppercase
    # gets normalised by ToLowerInvariant, so 'UPPERCASE.bad' is technically
    # accepted as a case-insensitive variant of 'uppercase.bad').
    $r = Invoke-CwcOnHost -Args @('firewall','host-add','bad..fqdn')
    Should-NotEqual $r.ExitCode 0
    Should-Match $r.Output 'Invalid FQDN'
}

Run-TestCase -Category denylist -Name 'host-add validates malformed target' -Test {
    Set-CwcConfig
    $r = Invoke-CwcOnHost -Args @('firewall','host-add','test.local','not-an-ip')
    Should-NotEqual $r.ExitCode 0
    Should-Match $r.Output 'Invalid target'
}
