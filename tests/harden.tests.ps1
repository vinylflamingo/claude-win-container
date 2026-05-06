# Harden watchdog tests.
# When harden is enabled, an in-container watchdog re-applies blackhole routes
# every 2s. These tests verify the watchdog recovers from tampering. Each test
# sleeps a few seconds inside the container to give the watchdog time to react.
#
# Diagnostic appendix: each test echoes the watchdog log at the end so failures
# show what the watchdog actually did. The log lives at C:\cwc-watchdog\watchdog.log
# inside the container.

Run-TestCase -Category harden -Name 'watchdog re-applies removed blackhole route' -Test {
    Set-CwcConfig -LockdownLan $true -HardenEnabled $true
    # Single-quoted to avoid host-side interpolation; the container's PowerShell
    # parses this as a script. Diagnostic appendix at the end dumps the watchdog
    # log so failures show what the watchdog actually did (or didn't).
    $cmd = @'
$initial = Get-NetRoute -DestinationPrefix '192.168.0.0/16' -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Output "INITIAL=$($initial.NextHop)"
Remove-NetRoute -DestinationPrefix '192.168.0.0/16' -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 6
$after = Get-NetRoute -DestinationPrefix '192.168.0.0/16' -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Output "AFTER=$($after.NextHop)"
Write-Output "---WATCHDOG-LOG---"
if (Test-Path 'C:\cwc-watchdog\watchdog.log') {
    Get-Content 'C:\cwc-watchdog\watchdog.log' -Tail 30
} else {
    Write-Output "WATCHDOG_LOG_MISSING"
}
'@
    $out = Invoke-InContainer $cmd
    Should-Match $out 'INITIAL=0\.0\.0\.0' -Because 'blackhole should be present at session start'
    Should-Match $out 'AFTER=0\.0\.0\.0' -Because "watchdog should re-apply blackhole within 6s. Output:`n$out"
}

Run-TestCase -Category harden -Name 'watchdog removes unauthorized RFC1918 allow-route' -Test {
    Set-CwcConfig -LockdownLan $true -HardenEnabled $true
    $cmd = @'
# Find the active interface.
$idx = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).InterfaceIndex
$gw  = (Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
# Add an unauthorized /32 allow-route.
try {
    New-NetRoute -DestinationPrefix '192.168.99.99/32' -InterfaceIndex $idx -NextHop $gw -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    Write-Output "ADDED=true"
} catch { Write-Output "ADDED=false" }
Start-Sleep -Seconds 6
$present = Get-NetRoute -DestinationPrefix '192.168.99.99/32' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -ne '0.0.0.0' }
if ($present) { Write-Output "STILL_PRESENT=true" } else { Write-Output "STILL_PRESENT=false" }
'@
    $out = Invoke-InContainer $cmd
    Should-Match $out 'ADDED=true' -Because 'agent should be able to add the route initially (admin in container)'
    Should-Match $out 'STILL_PRESENT=false' -Because 'watchdog should remove the unauthorized route within 6s'
}

Run-TestCase -Category harden -Name 'watchdog restores hosts file after tampering' -Test {
    Set-CwcConfig -LockdownLan $true -HardenEnabled $true
    $cmd = @'
$path = 'C:\Windows\System32\drivers\etc\hosts'
$baseline = Get-Content $path -Raw
Add-Content -LiteralPath $path -Value "1.2.3.4`tinjected.example.com"
Start-Sleep -Seconds 6
$after = Get-Content $path -Raw
if ($after -match 'injected\.example\.com') { Write-Output "STILL=true" } else { Write-Output "STILL=false" }
'@
    $out = Invoke-InContainer $cmd
    Should-Match $out 'STILL=false' -Because 'watchdog should restore hosts file from snapshot'
}

Run-TestCase -Category harden -Name 'no watchdog when harden disabled' -Test {
    Set-CwcConfig -LockdownLan $true -HardenEnabled $false
    $cmd = @'
Remove-NetRoute -DestinationPrefix '192.168.0.0/16' -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 6
$after = Get-NetRoute -DestinationPrefix '192.168.0.0/16' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($after) { Write-Output "STILL_BLOCKED=true" } else { Write-Output "STILL_BLOCKED=false" }
'@
    $out = Invoke-InContainer $cmd
    Should-Match $out 'STILL_BLOCKED=false' -Because 'without harden, removed blackhole stays removed'
}
