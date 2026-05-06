# Spike 2: host-side firewall enforcement on Docker Desktop Windows containers.
#
# Spike 1 established that Docker Desktop's Windows containers don't register with
# either Hyper-V Firewall (no VM creator) or Hyper-V VM Manager (Get-VM blind to
# HCS-managed containers). So both backends from the original plan are inapplicable.
#
# This spike tests whether plain Windows Defender Firewall outbound rules -- scoped
# to the container's source IP/subnet or to the NAT bridge interface -- can do the
# job. If they can, harden's implementation is dramatically simpler than HNS/VFP
# scripting.
#
# Approaches tested:
#   A. Outbound rule with LocalAddress = Docker NAT subnet, RemoteAddress = $BlockIp
#      (source-IP filter; should fire on traffic before NAT translation)
#   B. Outbound rule with InterfaceAlias = Docker NAT bridge adapter, RemoteAddress = $BlockIp
#      (interface filter; only sees container-bridge traffic)
#   C. Combined: both A and B together
#
# For each approach we measure:
#   - Does the rule block container egress to $BlockIp?
#   - Does it leave $AllowIp reachable from the container?
#   - Does it leave host egress to $BlockIp untouched? (regression check -- we
#     don't want to accidentally block our own host)
#
# Run AS ADMINISTRATOR. Cleans up after itself unless -KeepRules is passed.

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$BlockIp = '1.1.1.1',
    [string]$AllowIp = '8.8.8.8',
    [string]$Image   = 'mcr.microsoft.com/windows/servercore:ltsc2019',
    [switch]$KeepRules
)

$ErrorActionPreference = 'Stop'
$script:results = @()

function Add-Result {
    param([string]$Step, [string]$Status, [string]$Detail = '')
    $script:results += [pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail }
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'INFO' { 'DarkGray' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("  [{0,-4}] {1}{2}" -f $Status, $Step, $(if ($Detail) { " -- $Detail" } else { '' })) -ForegroundColor $color
}

function Section([string]$title) {
    Write-Host ""
    Write-Host $title -ForegroundColor Cyan
    Write-Host ('-' * $title.Length) -ForegroundColor Cyan
}

function Test-ContainerReach {
    param([string]$Ip, [string]$Isolation = 'hyperv')
    $cmd = "if (Test-NetConnection $Ip -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) { 'REACHABLE' } else { 'BLOCKED' }"
    try {
        $out = & docker run --rm --isolation=$Isolation $Image powershell -NoProfile -Command $cmd 2>$null
        if (-not $out) { return 'NO_OUTPUT' }
        return ($out | Select-Object -Last 1).Trim()
    } catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

function Test-HostReach {
    param([string]$Ip)
    if (Test-NetConnection $Ip -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) {
        return 'REACHABLE'
    } else {
        return 'BLOCKED'
    }
}

function Remove-SpikeRule {
    param([string]$Name)
    Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

function Test-Approach {
    param(
        [string]$Label,
        [scriptblock]$AddRule
    )
    Write-Host ""
    Write-Host "  Approach $Label" -ForegroundColor White

    try {
        & $AddRule
        Add-Result "$Label rule add" 'PASS' ''
    } catch {
        Add-Result "$Label rule add" 'FAIL' $_.Exception.Message
        return @{ blocked = $false; allowed = $false; hostOk = $false }
    }

    Start-Sleep -Seconds 2

    $blockResult = Test-ContainerReach -Ip $BlockIp
    $blocked = ($blockResult -eq 'BLOCKED')
    Add-Result "$Label container -> $BlockIp" $(if ($blocked) { 'PASS' } else { 'FAIL' }) $blockResult

    $allowResult = Test-ContainerReach -Ip $AllowIp
    $allowed = ($allowResult -eq 'REACHABLE')
    Add-Result "$Label container -> $AllowIp" $(if ($allowed) { 'PASS' } else { 'FAIL' }) $allowResult

    $hostResult = Test-HostReach -Ip $BlockIp
    $hostOk = ($hostResult -eq 'REACHABLE')
    Add-Result "$Label host -> $BlockIp (regression)" $(if ($hostOk) { 'PASS' } else { 'FAIL' }) "$hostResult (host should not be blocked)"

    return @{ blocked = $blocked; allowed = $allowed; hostOk = $hostOk }
}

Section 'Environment'

$os = Get-CimInstance Win32_OperatingSystem
Add-Result 'OS' 'INFO' "$($os.Caption) build $($os.BuildNumber)"

try {
    $dockerVer = & docker version --format '{{.Server.Version}}' 2>$null
    Add-Result 'Docker daemon' 'PASS' "v$dockerVer"
} catch {
    Add-Result 'Docker daemon' 'FAIL' $_.Exception.Message
    exit 1
}

Section 'Discovery -- Docker network topology'

# Get Docker's nat network details
$subnet  = $null
$gateway = $null
try {
    $natRaw = & docker network inspect nat 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'docker network inspect nat failed' }
    $natNet = $natRaw | ConvertFrom-Json
    if ($natNet -and $natNet[0].IPAM.Config) {
        $subnet  = $natNet[0].IPAM.Config[0].Subnet
        $gateway = $natNet[0].IPAM.Config[0].Gateway
        Add-Result "Docker 'nat' network" 'PASS' "subnet=$subnet gateway=$gateway"
    } else {
        Add-Result "Docker 'nat' network" 'FAIL' 'no IPAM config in network inspect output'
    }
} catch {
    Add-Result "Docker 'nat' network" 'FAIL' $_.Exception.Message
}

# Find the host adapter that owns the gateway IP
$natAdapter = $null
$natIfAlias = $null
if ($gateway) {
    try {
        $ipBinding = Get-NetIPAddress -IPAddress $gateway -ErrorAction Stop | Select-Object -First 1
        $natAdapter = Get-NetAdapter -InterfaceIndex $ipBinding.InterfaceIndex -ErrorAction Stop
        $natIfAlias = $natAdapter.InterfaceAlias
        Add-Result 'NAT bridge adapter' 'PASS' "alias='$natIfAlias' idx=$($natAdapter.InterfaceIndex)"
    } catch {
        Add-Result 'NAT bridge adapter' 'WARN' "could not resolve adapter for gateway $gateway -- $($_.Exception.Message)"
    }
}

# WinNAT entries (informational)
try {
    $netNats = Get-NetNat -ErrorAction Stop
    if ($netNats) {
        foreach ($n in $netNats) {
            Add-Result '  NetNat' 'INFO' "$($n.Name) prefix=$($n.InternalIPInterfaceAddressPrefix)"
        }
    } else {
        Add-Result 'NetNat entries' 'INFO' '(none)'
    }
} catch {
    Add-Result 'NetNat enumeration' 'WARN' $_.Exception.Message
}

# Network compartments -- Windows isolates container networking here
try {
    $compartments = Get-NetCompartment -ErrorAction Stop
    foreach ($c in $compartments) {
        Add-Result '  Compartment' 'INFO' "id=$($c.CompartmentId) desc='$($c.CompartmentDescription)'"
    }
} catch {
    Add-Result 'Compartments' 'INFO' "Get-NetCompartment unavailable: $($_.Exception.Message)"
}

if (-not $subnet) {
    Write-Host ''
    Write-Host 'Aborting -- no Docker NAT subnet detected; nothing to scope rules to.' -ForegroundColor Red
    exit 1
}

# Pre-pull image so the test container starts fast
& docker pull $Image 2>&1 | Out-Null

Section 'Baseline'

$baseBlock = Test-ContainerReach -Ip $BlockIp
Add-Result "baseline container -> $BlockIp" $(if ($baseBlock -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $baseBlock

$baseAllow = Test-ContainerReach -Ip $AllowIp
Add-Result "baseline container -> $AllowIp" $(if ($baseAllow -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $baseAllow

$baseHost = Test-HostReach -Ip $BlockIp
Add-Result "baseline host -> $BlockIp" $(if ($baseHost -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $baseHost

if ($baseBlock -ne 'REACHABLE') {
    Write-Host ''
    Write-Host "Warning: container can't reach $BlockIp at baseline; rule tests will be inconclusive." -ForegroundColor Yellow
}

Section 'Approach A -- LocalAddress (source-IP) scope'

$ruleA = 'cwc-spike-fw-A'
Remove-SpikeRule $ruleA

$resultA = Test-Approach -Label 'A' -AddRule {
    New-NetFirewallRule `
        -Name $ruleA `
        -DisplayName 'cwc spike A: block container subnet to test IP' `
        -Direction Outbound `
        -LocalAddress $subnet `
        -RemoteAddress $BlockIp `
        -Action Block `
        -Profile Any `
        -Enabled True | Out-Null
}

Remove-SpikeRule $ruleA

Section 'Approach B -- InterfaceAlias scope'

$resultB = $null
if ($natIfAlias) {
    $ruleB = 'cwc-spike-fw-B'
    Remove-SpikeRule $ruleB

    $resultB = Test-Approach -Label 'B' -AddRule {
        New-NetFirewallRule `
            -Name $ruleB `
            -DisplayName 'cwc spike B: block on NAT bridge to test IP' `
            -Direction Outbound `
            -InterfaceAlias $natIfAlias `
            -RemoteAddress $BlockIp `
            -Action Block `
            -Profile Any `
            -Enabled True | Out-Null
    }

    Remove-SpikeRule $ruleB
} else {
    Add-Result 'B' 'WARN' 'skipped -- NAT bridge adapter not resolved'
}

Section 'Approach C -- combined'

$resultC = $null
if ($natIfAlias) {
    $ruleC = 'cwc-spike-fw-C'
    Remove-SpikeRule $ruleC

    $resultC = Test-Approach -Label 'C' -AddRule {
        New-NetFirewallRule `
            -Name $ruleC `
            -DisplayName 'cwc spike C: block container subnet on NAT bridge' `
            -Direction Outbound `
            -LocalAddress $subnet `
            -InterfaceAlias $natIfAlias `
            -RemoteAddress $BlockIp `
            -Action Block `
            -Profile Any `
            -Enabled True | Out-Null
    }

    Remove-SpikeRule $ruleC
} else {
    Add-Result 'C' 'WARN' 'skipped -- NAT bridge adapter not resolved'
}

Section 'Verdict'

$winning = @()
foreach ($entry in @(@{ Label = 'A'; Result = $resultA }, @{ Label = 'B'; Result = $resultB }, @{ Label = 'C'; Result = $resultC })) {
    $r = $entry.Result
    if ($r -and $r.blocked -and $r.allowed -and $r.hostOk) {
        $winning += $entry.Label
    }
}

$pass = ($script:results | Where-Object Status -eq 'PASS').Count
$fail = ($script:results | Where-Object Status -eq 'FAIL').Count
Write-Host ("  PASS: {0}" -f $pass) -ForegroundColor Green
Write-Host ("  FAIL: {0}" -f $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'DarkGray' })

Write-Host ''
if ($winning.Count -gt 0) {
    Write-Host "  Verdict: GO -- approach(es) $($winning -join ', ') work cleanly. Build harden using the simplest." -ForegroundColor Green
} else {
    Write-Host '  Verdict: INVESTIGATE -- no Defender Firewall approach blocks container egress while leaving' -ForegroundColor Yellow
    Write-Host '  host egress and other-IP container egress intact. Next layer to try: HNS / VFP policies.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Per-approach results:' -ForegroundColor DarkGray
foreach ($entry in @(@{ Label = 'A'; Result = $resultA }, @{ Label = 'B'; Result = $resultB }, @{ Label = 'C'; Result = $resultC })) {
    $r = $entry.Result
    if ($r) {
        Write-Host "  $($entry.Label): block=$($r.blocked) allow=$($r.allowed) hostOk=$($r.hostOk)"
    } else {
        Write-Host "  $($entry.Label): not tested"
    }
}
Write-Host ''

if ($fail -gt 0 -and $winning.Count -eq 0) { exit 1 } else { exit 0 }
