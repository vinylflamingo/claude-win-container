# Spike: can Hyper-V Firewall (or its predecessor, vNIC extended ACLs) effectively
# block Docker Desktop container egress at the host level?
#
# This is a one-off investigative script, NOT part of the regular test suite. The
# question we're answering: when `cwc harden` ships, which backend should it use on
# this host, and does it actually work?
#
# Hypotheses tested:
#   H1: Hyper-V Firewall cmdlets are available on this host (Win 11 22H2+ / Server 2025).
#   H2: Docker Desktop registers a VMCreator that Hyper-V Firewall recognises.
#   H3: A rule blocking IP X actually stops the container reaching X.
#   H4: Other public IPs remain reachable (no over-blocking).
#   H5: Result holds for both hyperv and process isolation (where supported on host).
#   H6: As a fallback for older OSes, vNIC extended ACLs work against Docker UVMs.
#
# Run AS ADMINISTRATOR. Cleans up after itself unless -KeepRule is passed.
#
# Verdict legend at end:
#   GO         — Hyper-V Firewall path viable; build C1 backend.
#   FALLBACK   — only the legacy vNIC-ACL path works; build C2 backend.
#   PARTIAL    — works in some isolation modes but not all; need to constrain harden.
#   INVESTIGATE — neither path works cleanly; revisit design.
#
# Usage:
#   .\tests\spikes\hyperv-firewall.ps1                     # full run, default IPs
#   .\tests\spikes\hyperv-firewall.ps1 -KeepRule           # leave rule in place for inspection
#   .\tests\spikes\hyperv-firewall.ps1 -BlockIp 1.0.0.1    # use a different sentinel IP

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$BlockIp = '1.1.1.1',
    [string]$AllowIp = '8.8.8.8',
    [string]$Image   = 'mcr.microsoft.com/windows/servercore:ltsc2019',
    [switch]$KeepRule,
    [switch]$SkipProcessIsolation
)

$ErrorActionPreference = 'Stop'
$script:results = @()

function Add-Result {
    param([string]$Step, [string]$Status, [string]$Detail = '')
    $script:results += [pscustomobject]@{
        Step = $Step; Status = $Status; Detail = $Detail
    }
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'INFO' { 'DarkGray' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("  [{0,-4}] {1}{2}" -f $Status, $Step, $(if ($Detail) { " — $Detail" } else { '' })) -ForegroundColor $color
}

function Section([string]$title) {
    Write-Host ""
    Write-Host $title -ForegroundColor Cyan
    Write-Host ('-' * $title.Length) -ForegroundColor Cyan
}

# Run a probe inside a one-shot container. Returns 'REACHABLE' or 'BLOCKED'.
# Uses Test-NetConnection -Port 443 -Quiet so the test exercises a real TCP SYN, not ICMP.
function Test-ContainerReach {
    param(
        [Parameter(Mandatory)] [string]$Ip,
        [Parameter(Mandatory)] [string]$Isolation,
        [int]$TimeoutSec = 8
    )
    $cmd = "if (Test-NetConnection $Ip -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) { 'REACHABLE' } else { 'BLOCKED' }"
    try {
        $out = & docker run --rm --isolation=$Isolation $Image powershell -NoProfile -Command $cmd 2>$null
        if (-not $out) { return 'NO_OUTPUT' }
        return ($out | Select-Object -Last 1).Trim()
    } catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

Section 'Environment'

# OS detection
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
Add-Result 'OS' 'INFO' "$($os.Caption) build $build"

# Hyper-V Firewall presence
$hasHyperVFirewall = [bool](Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)
if ($hasHyperVFirewall) {
    Add-Result 'Hyper-V Firewall cmdlets' 'PASS' 'New-NetFirewallHyperVRule available'
} else {
    Add-Result 'Hyper-V Firewall cmdlets' 'WARN' 'not available (pre-22H2 OS); will test vNIC ACL fallback only'
}

# Legacy VM ACL cmdlets
$hasVmAcl = [bool](Get-Command Add-VMNetworkAdapterExtendedAcl -ErrorAction SilentlyContinue)
if ($hasVmAcl) {
    Add-Result 'Hyper-V VM ACL cmdlets' 'PASS' 'Add-VMNetworkAdapterExtendedAcl available'
} else {
    Add-Result 'Hyper-V VM ACL cmdlets' 'WARN' 'not available — Hyper-V management module missing'
}

# Docker reachable
try {
    $dockerVer = & docker version --format '{{.Server.Version}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "docker version exit $LASTEXITCODE" }
    Add-Result 'Docker daemon' 'PASS' "v$dockerVer"
} catch {
    Add-Result 'Docker daemon' 'FAIL' $_.Exception.Message
    Write-Host ''
    Write-Host 'Aborting — Docker not reachable.' -ForegroundColor Red
    exit 1
}

# Pre-pull image so first container start in the test isn't pulling
Write-Host ''
Write-Host "Pulling test image ($Image)..." -ForegroundColor DarkGray
& docker pull $Image 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Add-Result 'Image pull' 'FAIL' "docker pull $Image failed"
    exit 1
}
Add-Result 'Image pull' 'PASS' $Image

Section 'C1: Hyper-V Firewall path'

$dockerCreator = $null
if ($hasHyperVFirewall) {
    try {
        $creators = Get-NetFirewallHyperVVMCreator -ErrorAction Stop
        Add-Result 'VM creator enumeration' 'PASS' "$(@($creators).Count) creator(s) registered"
        foreach ($c in $creators) {
            Add-Result '  creator' 'INFO' "$($c.Name) [$($c.VMCreatorId)]"
        }
        # Best-guess match. Docker Desktop's name has historically been 'Docker Desktop' or similar.
        $dockerCreator = $creators | Where-Object { $_.Name -match 'docker|container' } | Select-Object -First 1
        if ($dockerCreator) {
            Add-Result 'Docker creator match' 'PASS' "$($dockerCreator.Name)"
        } else {
            Add-Result 'Docker creator match' 'FAIL' 'no creator matches /docker|container/ — see list above'
        }
    } catch {
        Add-Result 'VM creator enumeration' 'FAIL' $_.Exception.Message
    }
} else {
    Add-Result 'C1 path' 'WARN' 'skipped — Hyper-V Firewall unavailable'
}

# Determine which isolation modes to test
$isolationModes = @('hyperv')
if (-not $SkipProcessIsolation) {
    # Process isolation requires the container's base OS build to match the host's. The
    # ltsc2019 image works on any Windows 10/11 host with hyperv isolation; for process
    # isolation we'd need a base matching the host build, which we don't here. Skip
    # process isolation by default when using ltsc2019 image.
    if ($Image -match 'ltsc2022' -and $build -ge 20348) {
        $isolationModes += 'process'
    }
}

$c1Results = @{}
if ($hasHyperVFirewall -and $dockerCreator) {
    foreach ($iso in $isolationModes) {
        Write-Host ""
        Write-Host "  Isolation mode: $iso" -ForegroundColor White

        $baseline = Test-ContainerReach -Ip $BlockIp -Isolation $iso
        Add-Result "baseline reach $BlockIp ($iso)" $(if ($baseline -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $baseline

        if ($baseline -ne 'REACHABLE') {
            Add-Result "skip rule test ($iso)" 'INFO' 'baseline failed; rule test would be inconclusive'
            continue
        }

        $ruleName = "cwc-spike-block-$($BlockIp -replace '\.','_')"
        try {
            $existing = Get-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
            if ($existing) { Remove-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue }

            New-NetFirewallHyperVRule `
                -Name $ruleName `
                -DisplayName "cwc spike: block $BlockIp" `
                -VMCreatorId $dockerCreator.VMCreatorId `
                -Direction Outbound `
                -RemoteAddresses $BlockIp `
                -Action Block | Out-Null
            Add-Result "rule add ($iso)" 'PASS' $ruleName
        } catch {
            Add-Result "rule add ($iso)" 'FAIL' $_.Exception.Message
            continue
        }

        Start-Sleep -Seconds 2  # Give the firewall a moment to propagate

        $afterBlock = Test-ContainerReach -Ip $BlockIp -Isolation $iso
        $blockOK = ($afterBlock -eq 'BLOCKED')
        Add-Result "rule blocks $BlockIp ($iso)" $(if ($blockOK) { 'PASS' } else { 'FAIL' }) $afterBlock

        $allowResult = Test-ContainerReach -Ip $AllowIp -Isolation $iso
        $allowOK = ($allowResult -eq 'REACHABLE')
        Add-Result "$AllowIp still reaches ($iso)" $(if ($allowOK) { 'PASS' } else { 'FAIL' }) $allowResult

        $c1Results[$iso] = @{ blocked = $blockOK; allowed = $allowOK }

        if (-not $KeepRule) {
            Remove-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            $afterCleanup = Test-ContainerReach -Ip $BlockIp -Isolation $iso
            Add-Result "cleanup restores reach ($iso)" $(if ($afterCleanup -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $afterCleanup
        } else {
            Add-Result "rule retained ($iso)" 'INFO' "-KeepRule passed; rule $ruleName left in place"
        }
    }
}

Section 'C2: legacy vNIC extended ACL path'

if (-not $hasVmAcl) {
    Add-Result 'C2 path' 'WARN' 'skipped — VM ACL cmdlets unavailable'
} else {
    # Strategy: start a long-running container in hyperv isolation, find its UVM, apply
    # an extended ACL blocking $BlockIp, probe from inside, then remove and verify.
    Write-Host ""
    Write-Host "  Starting probe container..." -ForegroundColor White

    $cid = $null
    try {
        $cid = & docker run -d --rm --isolation=hyperv $Image powershell -NoProfile -Command 'Start-Sleep 120' 2>$null
        if (-not $cid -or $LASTEXITCODE -ne 0) { throw 'docker run failed' }
        $cid = $cid.Trim()
        Add-Result 'probe container start' 'PASS' "id=$($cid.Substring(0,12))"
    } catch {
        Add-Result 'probe container start' 'FAIL' $_.Exception.Message
    }

    $vm = $null
    if ($cid) {
        # Hyper-V isolated containers create a VM whose name embeds part of the container ID.
        # The exact format has changed across Docker versions — try a few patterns.
        Start-Sleep -Seconds 3
        try {
            $vms = Get-VM -ErrorAction Stop
            $vm = $vms | Where-Object { $_.Name -match $cid.Substring(0,12) -or $_.Name -match 'docker' } | Select-Object -First 1
            if ($vm) {
                Add-Result 'UVM lookup' 'PASS' "VM=$($vm.Name)"
            } else {
                Add-Result 'UVM lookup' 'FAIL' "no Hyper-V VM matched container; saw: $((($vms | Select-Object -First 5).Name) -join ', ')"
            }
        } catch {
            Add-Result 'UVM lookup' 'FAIL' $_.Exception.Message
        }
    }

    if ($vm) {
        try {
            $adapter = Get-VMNetworkAdapter -VM $vm | Select-Object -First 1
            if (-not $adapter) { throw 'no vNetwork adapter on VM' }

            # Baseline
            $baseline = & docker exec $cid powershell -NoProfile -Command "if (Test-NetConnection $BlockIp -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) { 'REACHABLE' } else { 'BLOCKED' }" 2>$null
            $baseline = ($baseline | Select-Object -Last 1).Trim()
            Add-Result "C2 baseline reach $BlockIp" $(if ($baseline -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $baseline

            if ($baseline -eq 'REACHABLE') {
                Add-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $adapter `
                    -Action Deny -Direction Outbound `
                    -RemoteIPAddress $BlockIp -Weight 100 -ErrorAction Stop
                Add-Result 'C2 ACL add' 'PASS' "Deny outbound -> $BlockIp"

                Start-Sleep -Seconds 2
                $after = & docker exec $cid powershell -NoProfile -Command "if (Test-NetConnection $BlockIp -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) { 'REACHABLE' } else { 'BLOCKED' }" 2>$null
                $after = ($after | Select-Object -Last 1).Trim()
                Add-Result "C2 ACL blocks $BlockIp" $(if ($after -eq 'BLOCKED') { 'PASS' } else { 'FAIL' }) $after

                $allowAfter = & docker exec $cid powershell -NoProfile -Command "if (Test-NetConnection $AllowIp -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) { 'REACHABLE' } else { 'BLOCKED' }" 2>$null
                $allowAfter = ($allowAfter | Select-Object -Last 1).Trim()
                Add-Result "C2 $AllowIp still reaches" $(if ($allowAfter -eq 'REACHABLE') { 'PASS' } else { 'FAIL' }) $allowAfter

                Remove-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $adapter -Direction Outbound -ErrorAction SilentlyContinue
                Add-Result 'C2 ACL cleanup' 'PASS' 'removed'
            }
        } catch {
            Add-Result 'C2 ACL test' 'FAIL' $_.Exception.Message
        }
    }

    # Stop container
    if ($cid) {
        & docker kill $cid 2>$null | Out-Null
    }
}

Section 'Verdict'

$passes = ($script:results | Where-Object Status -eq 'PASS').Count
$fails  = ($script:results | Where-Object Status -eq 'FAIL').Count
Write-Host ("  PASS: {0}" -f $passes) -ForegroundColor Green
Write-Host ("  FAIL: {0}" -f $fails)  -ForegroundColor $(if ($fails) { 'Red' } else { 'DarkGray' })

# Decision logic
$c1Works = $hasHyperVFirewall -and $dockerCreator -and `
           $c1Results.Count -gt 0 -and `
           ($c1Results.Values | Where-Object { $_.blocked -and $_.allowed }).Count -gt 0

$c1AllModes = $hasHyperVFirewall -and $dockerCreator -and `
              $c1Results.Count -eq $isolationModes.Count -and `
              -not ($c1Results.Values | Where-Object { -not ($_.blocked -and $_.allowed) })

$c2Works = $hasVmAcl -and (
    ($script:results | Where-Object { $_.Step -like 'C2 ACL blocks*' -and $_.Status -eq 'PASS' }).Count -gt 0
)

$verdict = if ($c1AllModes) {
    'GO — build C1 (Hyper-V Firewall) as primary backend.'
} elseif ($c1Works -and $c2Works) {
    'PARTIAL — C1 works for some isolation modes; use C2 to fill gaps. Build both.'
} elseif ($c1Works) {
    'PARTIAL — C1 works for tested isolation modes only; document constraint in cwc harden.'
} elseif ($c2Works) {
    'FALLBACK — only legacy vNIC ACL works on this host. Build C2; document C1 as future work.'
} else {
    'INVESTIGATE — neither backend works cleanly. Review failures above before building harden.'
}

Write-Host ''
Write-Host "  Verdict: $verdict" -ForegroundColor Yellow
Write-Host ''

# Compact data dump for the planning doc
Write-Host 'Notes for follow-up:' -ForegroundColor DarkGray
Write-Host "  - C1 supported on this OS: $hasHyperVFirewall"
Write-Host "  - Docker VMCreator found:  $([bool]$dockerCreator) $(if ($dockerCreator) { "($($dockerCreator.Name))" })"
Write-Host "  - C1 results per isolation: $((($c1Results.GetEnumerator() | ForEach-Object { "$($_.Key)=block:$($_.Value.blocked) allow:$($_.Value.allowed)" }) -join '; '))"
Write-Host "  - C2 cmdlets present:      $hasVmAcl"
Write-Host ''

if ($fails -gt 0) { exit 1 } else { exit 0 }
