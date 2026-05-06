# Filesystem boundary tests.
# Verifies what's bind-mounted into the container, what's hidden, and that read-only
# mounts actually block writes.

Run-TestCase -Category filesystem -Name 'workspace bind mount visible' -Test {
    Set-CwcConfig
    $out = Invoke-InContainer 'Get-Content C:\workspace\WORKSPACE.txt'
    Should-Match $out 'workspace marker'
}

Run-TestCase -Category filesystem -Name 'host home path invisible to container' -Test {
    # Sanity: a host path that we did NOT bind-mount should not exist inside the container.
    Set-CwcConfig
    $out = Invoke-InContainer ('Test-Path "{0}"' -f $env:USERPROFILE)
    Should-Match $out 'False' -Because 'docker should not leak host paths into the container'
}

Run-TestCase -Category filesystem -Name 'configured RO mount visible at C:\docs\<name>' -Test {
    Set-CwcConfig -Mounts @{
        rofix = @{ source = $script:fixtures.ro; target = 'C:\docs\rofix'; readonly = $true }
    }
    $out = Invoke-InContainer 'Get-Content C:\docs\rofix\readme.txt'
    Should-Match $out 'ro fixture content'
}

Run-TestCase -Category filesystem -Name 'unconfigured C:\docs path absent' -Test {
    Set-CwcConfig
    $out = Invoke-InContainer 'Test-Path C:\docs\notconfigured'
    Should-Match $out 'False'
}

Run-TestCase -Category filesystem -Name 'RO mount blocks writes' -Test {
    Set-CwcConfig -Mounts @{
        rofix = @{ source = $script:fixtures.ro; target = 'C:\docs\rofix'; readonly = $true }
    }
    $out = Invoke-InContainer 'try { Set-Content C:\docs\rofix\new.txt -Value x -ErrorAction Stop; Write-Output WROTE } catch { Write-Output BLOCKED }'
    Should-Match $out 'BLOCKED' -Because 'readonly bind mount must reject writes'
}

Run-TestCase -Category filesystem -Name 'RW mount allows writes and reflects on host' -Test {
    Set-CwcConfig -Mounts @{
        rwfix = @{ source = $script:fixtures.rw; target = 'C:\docs\rwfix'; readonly = $false }
    }
    $marker = "test-marker-$(Get-Random)"
    $out = Invoke-InContainer "Set-Content C:\docs\rwfix\test.txt -Value $marker; Get-Content C:\docs\rwfix\test.txt"
    Should-Match $out $marker
    $hostFile = Join-Path $script:fixtures.rw 'test.txt'
    Should-BeTrue (Test-Path $hostFile) 'RW mount writes should land on host'
    Should-Match (Get-Content $hostFile -Raw) $marker
}

Run-TestCase -Category filesystem -Name 'mount with missing source is skipped' -Test {
    $bogus = Join-Path $env:TEMP "cwc-tests-missing-$(Get-Random)"
    Set-CwcConfig -Mounts @{
        gone = @{ source = $bogus; target = 'C:\docs\gone'; readonly = $true }
    }
    # The launcher should warn and continue; container should still start cleanly.
    $out = Invoke-InContainer 'Test-Path C:\docs\gone; Test-Path C:\workspace'
    Should-Match $out 'False[\s\S]+True' -Because 'missing-source mount skipped, workspace still mounted'
}
