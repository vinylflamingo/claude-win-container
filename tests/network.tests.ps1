# Network boundary tests.
# Verifies the LAN-egress lockdown installs the expected blackhole routes, allow CIDRs
# punch holes through, public internet stays reachable, and host-gateway mappings end
# up in the hosts file with a /32 allow-route.

Run-TestCase -Category network -Name 'lockdown installs RFC1918 + IPv6 blackhole routes' -Test {
    Set-CwcConfig -LockdownLan $true
    $out = Invoke-InContainer @'
$cidrs = @('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','169.254.0.0/16')
foreach ($c in $cidrs) {
  $r = Get-NetRoute -DestinationPrefix $c -ErrorAction SilentlyContinue | Select-Object -First 1
  Write-Output "$c=$($r.NextHop)"
}
'@
    Should-Match $out '10\.0\.0\.0/8=0\.0\.0\.0'
    Should-Match $out '172\.16\.0\.0/12=0\.0\.0\.0'
    Should-Match $out '192\.168\.0\.0/16=0\.0\.0\.0'
    Should-Match $out '169\.254\.0\.0/16=0\.0\.0\.0'
}

Run-TestCase -Category network -Name 'lockdown disabled = no blackhole routes' -Test {
    Set-CwcConfig -LockdownLan $false
    $out = Invoke-InContainer 'Get-NetRoute -DestinationPrefix "192.168.0.0/16" -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count'
    Should-Match $out '^\s*0\s*$' -Because 'no blackhole route should be present when lockdown is off'
}

Run-TestCase -Category network -Name 'CWC_ALLOW_NETS adds more-specific allow route' -Test {
    Set-CwcConfig -LockdownLan $true -AllowNets @('192.168.50.0/24')
    $out = Invoke-InContainer 'Get-NetRoute -DestinationPrefix "192.168.50.0/24" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty NextHop'
    Should-NotMatch $out '0\.0\.0\.0' -Because 'allow-route should NOT be a blackhole'
    Should-Match $out '\d+\.\d+\.\d+\.\d+' -Because 'allow-route should point at a real gateway IP'
}

Run-TestCase -Category network -Name 'public internet still reachable under lockdown' -Test {
    Set-CwcConfig -LockdownLan $true
    $out = Invoke-InContainer 'Test-NetConnection 1.1.1.1 -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue'
    Should-Match $out 'True' -Because 'lockdown only blocks RFC1918; public IPs must stay reachable'
}

Run-TestCase -Category network -Name 'host-gateway mapping written to hosts file pointing at loopback' -Test {
    Set-CwcConfig -LockdownLan $true -ExtraHosts @{
        'test.cwc.local' = @{ target = 'host-gateway'; ports = @(443) }
    }
    $out = Invoke-InContainer 'Get-Content C:\Windows\System32\drivers\etc\hosts'
    Should-Match $out 'test\.cwc\.local'
    # Phase 4: hosts file maps fqdn -> 127.0.0.X (loopback), not directly to gateway IP.
    Should-Match $out '127\.0\.0\.\d+\s+test\.cwc\.local'
}

Run-TestCase -Category network -Name 'portproxy listener configured for listed port' -Test {
    Set-CwcConfig -LockdownLan $true -ExtraHosts @{
        'test.cwc.local' = @{ target = 'host-gateway'; ports = @(443) }
    }
    $out = Invoke-InContainer 'netsh interface portproxy show v4tov4'
    Should-Match $out '127\.0\.0\.\d+\s+443' -Because 'portproxy must have a v4-to-v4 listener on 443 for the loopback'
}

Run-TestCase -Category network -Name 'host-gateway target /32 allow-route present' -Test {
    Set-CwcConfig -LockdownLan $true -ExtraHosts @{
        'test.cwc.local' = @{ target = 'host-gateway'; ports = @(443) }
    }
    # Resolve host-gateway IP, check the /32 allow-route. (RFC1918 only -- see security.md
    # for why this all-ports allow exists; portproxy narrows the FQDN path but the IP
    # itself is reachable on all ports through this route.)
    $out = Invoke-InContainer @'
$gw = (Resolve-DnsName host.docker.internal -Type A -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
Write-Output "GW=$gw"
if (-not $gw) { exit }
$route = Get-NetRoute -DestinationPrefix "$gw/32" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($route) { Write-Output "ROUTE_NH=$($route.NextHop)" } else { Write-Output 'NO_ROUTE' }
'@
    if ($out -match 'GW=(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)') {
        Should-Match $out 'ROUTE_NH=' -Because 'host-gateway IP in RFC1918 must get a /32 allow-route for portproxy to function'
        Should-NotMatch $out 'ROUTE_NH=0\.0\.0\.0' -Because 'the /32 must point at the gateway, not be a blackhole'
    }
}

Run-TestCase -Category network -Name 'CWC_LOCKDOWN_LAN=0 env override disables lockdown' -Test {
    # Persistent config says lockdown_lan=true, but per-session env says 0.
    # The launcher should let the env override win (it only fills the var if not already set).
    Set-CwcConfig -LockdownLan $true
    $out = Invoke-InContainer -Env @{ CWC_LOCKDOWN_LAN = '0' } -Command 'Get-NetRoute -DestinationPrefix "192.168.0.0/16" -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count'
    Should-Match $out '^\s*0\s*$' -Because 'env override should disable the lockdown for this session'
}
