# Spike 5: empirically test whether a host-side egress block applied as a VFP
# rule (via vfpctrl.exe) actually blocks traffic from a Docker Desktop Windows
# container.
#
# Spike 4 (hns-acl-block.ps1) showed that the HNS-via-PowerShell path can attach
# an ACL to the endpoint object's metadata but the loaded HostNetworkingService
# module's POST does NOT push that policy down to VFP for enforcement. (The
# parallel HCN P/Invoke variant in spike 4 may close that gap; this spike tests
# the lower-level alternative.)
#
# This spike skips HNS entirely and writes the rule directly to the VFP port.
# vfpctrl is the layer where the actual filtering happens, so if a rule does
# not block traffic when added here, host-side enforcement on Docker Desktop
# Windows containers is not viable from a script -- pivot to the proxy/VM
# fallback.
#
# Hypotheses:
#   H1: We can add a custom VFP layer + group + rule on the container's port via
#       vfpctrl from the host.
#   H2: A block rule scoped to 172.16.0.0/12 stops container egress to the
#       gateway (which is in that range).
#   H3: Public-internet egress (1.1.1.1) is unaffected.
#   H4: Host egress is unaffected.
#   H5: Removing the layer restores container-to-gateway reachability.
#   H6: docker stop + docker start either preserves the rule (great for v2) or
#       drops it (we'd need to re-apply). VFP ports are typically destroyed and
#       recreated on container restart, so 'drops it' is the expected outcome.
#
# The spike adds ONE custom layer with a unique GUID-based ID, ONE group within
# it, and ONE block rule within the group. /remove-layer cleans up everything
# transitively. Even if that fails, the layer ID is uniquely scoped so it does
# not collide with Docker's own layers.
#
# Run AS ADMINISTRATOR. Spawns a probe container; cleans up unless -KeepProbe
# / -KeepRule is passed.
#
# Verdict legend:
#   GO          -- VFP rule blocks RFC1918 (gateway), allow target reachable,
#                  host unaffected, removal restores. Document the integration
#                  approach in the design doc; note the lifecycle gotchas.
#   INVESTIGATE -- partial: rule applied but no traffic effect, or applied with
#                  side effects (host blocked, public blocked, etc.). Capture
#                  the output for analysis; this is the kind of "applied but
#                  not enforced" gap we saw with HNS POST in spike 4.
#   NO-GO       -- vfpctrl rejected the rule, or the spike could not locate the
#                  port. If even vfpctrl-direct does not enforce, host-side
#                  enforcement is not viable on this Windows build via any
#                  PowerShell-reachable mechanism.
#
# Usage:
#   .\tests\spikes\vfp-rule-block.ps1
#   .\tests\spikes\vfp-rule-block.ps1 -KeepRule                # leave rule applied
#   .\tests\spikes\vfp-rule-block.ps1 -KeepProbe               # leave probe container running
#   .\tests\spikes\vfp-rule-block.ps1 -ContainerId <id>        # use existing container

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ContainerId,
    [string]$Image = 'mcr.microsoft.com/windows/servercore:ltsc2019',
    [string]$BlockedRange = '172.16.0.0/12',     # contains the default Docker nat gateway
    [string]$AllowIp = '1.1.1.1',
    [int]$Priority = 100,
    [switch]$KeepProbe,
    [switch]$KeepRule
)

$ErrorActionPreference = 'Stop'
$script:results = @()
$script:dump = [ordered]@{}

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
    Write-Host ''
    Write-Host $title -ForegroundColor Cyan
    Write-Host ('-' * $title.Length) -ForegroundColor Cyan
}

function Save-Dump {
    param([string]$Label, $Object)
    $script:dump[$Label] = $Object
    Write-Host ''
    Write-Host "  >>> $Label" -ForegroundColor DarkGray
    if ($null -eq $Object) {
        Write-Host '  (null)' -ForegroundColor DarkGray
        return
    }
    $text = if ($Object -is [string]) { $Object } else {
        try { $Object | Format-List * | Out-String } catch { $Object | Out-String }
    }
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim()) { Write-Host "  $line" -ForegroundColor Gray }
    }
}

function Import-HnsModuleIfPossible {
    if (Get-Command Get-HnsEndpoint -ErrorAction SilentlyContinue) { return $true }
    try { Import-Module HNS -ErrorAction Stop; return $true } catch {}
    try { Import-Module HostNetworkingService -ErrorAction Stop; return $true } catch {}
    foreach ($p in @(
        'C:\Program Files\WindowsPowerShell\Modules\HNS\HNS.psm1',
        'C:\Program Files\WindowsPowerShell\Modules\HostNetworkingService\HNS.psm1'
    )) {
        if (Test-Path $p) {
            try { Import-Module $p -ErrorAction Stop; return $true } catch {}
        }
    }
    return $false
}

function Test-ContainerPing {
    param(
        [Parameter(Mandatory)] [string]$Cid,
        [Parameter(Mandatory)] [string]$Target,
        [int]$Count = 2
    )
    $cmd = "if (Test-Connection -ComputerName $Target -Count $Count -Quiet -ErrorAction SilentlyContinue) { 'REACHABLE' } else { 'BLOCKED' }"
    try {
        $out = & docker exec $Cid powershell -NoProfile -Command $cmd 2>$null
        if (-not $out) { return 'NO_OUTPUT' }
        return ($out | Select-Object -Last 1).Trim()
    } catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

function Test-HostPing {
    param([string]$Target, [int]$Count = 2)
    if (Test-Connection -ComputerName $Target -Count $Count -Quiet -ErrorAction SilentlyContinue) {
        return 'REACHABLE'
    } else {
        return 'BLOCKED'
    }
}

function Find-MatchingEndpoint {
    param([string]$Ip, [string]$Mac)
    $endpoints = Get-HnsEndpoint
    $match = $null
    if ($Ip)  { $match = $endpoints | Where-Object { $_.IPAddress -eq $Ip } | Select-Object -First 1 }
    if (-not $match -and $Mac) {
        $normMac = ($Mac -replace '[:-]', '').ToUpper()
        $match = $endpoints | Where-Object {
            (($_.MacAddress -replace '[:-]', '').ToUpper()) -eq $normMac
        } | Select-Object -First 1
    }
    return $match
}

# Run vfpctrl and capture combined stdout+stderr. vfpctrl signals errors via
# specific output prefixes ("ERROR:", "Command ... failed") rather than exit
# codes -- callers must inspect the text.
function Invoke-Vfpctrl {
    param([Parameter(Mandatory)] [string]$VfpPath, [Parameter(Mandatory)] [string[]]$Args)
    $output = & $VfpPath @Args 2>&1 | Out-String
    return $output
}

function Test-VfpFailure {
    param([string]$Output)
    if (-not $Output) { return $false }
    # Treat any of these as failure:
    #   - "ERROR:" prefix on any line
    #   - "Error (N):" pattern (NTSTATUS-style HRESULT messages)
    #   - The help dump (vfpctrl prints help when an action is unrecognized;
    #     'VFP control and diagnostics utility' is the help banner). Without
    #     this check we'd false-positive a help dump as success.
    if ($Output -match '(?m)^\s*ERROR:')                    { return $true }
    if ($Output -match 'Error\s*\(\d+\)')                   { return $true }
    if ($Output -match 'VFP control and diagnostics utility') { return $true }
    return $false
}

# ---------------------------------------------------------------------------

Section 'Environment'

$os = Get-CimInstance Win32_OperatingSystem
Add-Result 'OS' 'INFO' "$($os.Caption) build $($os.BuildNumber)"

try {
    $dockerVer = & docker version --format '{{.Server.Version}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "docker version exit $LASTEXITCODE" }
    Add-Result 'Docker daemon' 'PASS' "v$dockerVer"
} catch {
    Add-Result 'Docker daemon' 'FAIL' $_.Exception.Message
    exit 1
}

$hnsLoaded = Import-HnsModuleIfPossible
if (-not $hnsLoaded) {
    Add-Result 'HNS module' 'FAIL' 'Get-HnsEndpoint not available -- needed to map container -> VFP port'
    exit 1
}
Add-Result 'HNS module' 'PASS' ''

$vfpPath = $null
foreach ($p in @(
    "$env:WINDIR\System32\vfpctrl.exe",
    "$env:WINDIR\SysWOW64\vfpctrl.exe"
)) {
    if (Test-Path $p) { $vfpPath = $p; break }
}
if (-not $vfpPath) {
    Add-Result 'vfpctrl.exe' 'FAIL' 'not found'
    exit 1
}
Add-Result 'vfpctrl.exe' 'PASS' $vfpPath

# ---------------------------------------------------------------------------

Section 'Probe container'

$ownProbe = $false
if (-not $ContainerId) {
    Write-Host "  Pulling $Image (if missing)..." -ForegroundColor DarkGray
    & docker pull $Image 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Add-Result 'image pull' 'FAIL' "docker pull $Image failed"
        exit 1
    }
    try {
        $cid = & docker run -d --isolation=hyperv $Image powershell -NoProfile -Command 'Start-Sleep 1200' 2>$null
        if (-not $cid -or $LASTEXITCODE -ne 0) { throw 'docker run failed' }
        $ContainerId = $cid.Trim()
        $ownProbe = $true
        Add-Result 'probe container start' 'PASS' "id=$($ContainerId.Substring(0,12))"
        Start-Sleep -Seconds 3
    } catch {
        Add-Result 'probe container start' 'FAIL' $_.Exception.Message
        exit 1
    }
} else {
    Add-Result 'probe container' 'INFO' "using $ContainerId (caller-supplied)"
}

$containerIp = $null; $containerMac = $null; $gateway = $null
try {
    $info = & docker inspect $ContainerId 2>$null | ConvertFrom-Json
    $netSettings = $info[0].NetworkSettings
    if ($netSettings.Networks.nat) {
        $containerIp  = $netSettings.Networks.nat.IPAddress
        $containerMac = $netSettings.Networks.nat.MacAddress
        $gateway      = $netSettings.Networks.nat.Gateway
    } elseif ($netSettings.IPAddress) {
        $containerIp  = $netSettings.IPAddress
        $containerMac = $netSettings.MacAddress
        $gateway      = $netSettings.Gateway
    }
    Add-Result 'docker inspect' 'PASS' "ip=$containerIp gw=$gateway mac=$containerMac"
} catch {
    Add-Result 'docker inspect' 'FAIL' $_.Exception.Message
    exit 1
}

$matchedEndpoint = Find-MatchingEndpoint -Ip $containerIp -Mac $containerMac
if (-not $matchedEndpoint) {
    Add-Result 'endpoint match' 'FAIL' "no HNS endpoint matched ip=$containerIp mac=$containerMac"
    exit 1
}

# Per spike 3's empirical finding: $endpoint.AdditionalParams.SwitchPortId is
# the VFP port name and equals the endpoint Id (uppercased). Prefer that over
# parsing /list-vmswitch-port output.
$vfpPortName = $null
if ($matchedEndpoint.AdditionalParams -and $matchedEndpoint.AdditionalParams.SwitchPortId) {
    $vfpPortName = $matchedEndpoint.AdditionalParams.SwitchPortId
}
if (-not $vfpPortName) {
    Add-Result 'VFP port' 'FAIL' 'endpoint has no SwitchPortId in AdditionalParams'
    exit 1
}
Add-Result 'VFP port' 'PASS' $vfpPortName

# Resolve the vSwitch GUID for this endpoint. On hosts with multiple vSwitches
# (Docker's NAT switch + a host vSwitch-LAN, etc.), per-port vfpctrl commands
# need /switch to disambiguate -- otherwise the port lookup fails with
# "The system cannot find the file specified" (vfpctrl re-uses ERROR_FILE_NOT_FOUND
# for "port not found in this scope"). The HnsNetwork object exposes SwitchGuid;
# the endpoint points to the network via VirtualNetwork.
$vfpSwitchId = $null
try {
    $hnsNet = Get-HnsNetwork -Id $matchedEndpoint.VirtualNetwork
    if ($hnsNet -and $hnsNet.SwitchGuid) { $vfpSwitchId = $hnsNet.SwitchGuid }
} catch {}
# Fall back to AdditionalParams.SwitchId if Get-HnsNetwork didn't work.
if (-not $vfpSwitchId -and $matchedEndpoint.AdditionalParams -and $matchedEndpoint.AdditionalParams.SwitchId) {
    $vfpSwitchId = $matchedEndpoint.AdditionalParams.SwitchId
}
if (-not $vfpSwitchId) {
    Add-Result 'VFP switch' 'FAIL' 'could not resolve switch GUID via Get-HnsNetwork or AdditionalParams.SwitchId'
    exit 1
}
Add-Result 'VFP switch' 'PASS' $vfpSwitchId

# Extract VM ID and full NIC name. For hyperv-isolated containers the VFP NIC
# name is "<vm-id>--<port-id>"; the port name in /list-vmswitch-port is just
# the port-id half. On some Windows builds vfpctrl per-port lookups want the
# full NIC name, on others just the port-id, with or without /switch and /vm.
# We probe a battery of patterns to find what this build accepts.
$vmId = $null
$nicName = $null
if ($matchedEndpoint.AdditionalParams) {
    $nicName = $matchedEndpoint.AdditionalParams.VmSwitchNicName
    if ($nicName -and $nicName -match '^([0-9A-Fa-f-]+)--') { $vmId = $matches[1] }
}
Add-Result 'VFP NIC name' 'INFO' "nic=$nicName vmId=$vmId"

# Each pattern is a list of modifier args (no action). The action gets appended
# at call time. The first pattern that lets vfpctrl successfully run
# /get-port-state is the one we use for all subsequent per-port commands.
$patterns = @(
    @{ name = '/switch /port <port-id>';            scope = @('/switch', $vfpSwitchId, '/port', $vfpPortName) },
    @{ name = '/port <port-id> (no switch)';        scope = @('/port', $vfpPortName) },
    @{ name = '/port <port-id> /switch';            scope = @('/port', $vfpPortName, '/switch', $vfpSwitchId) }
)
if ($nicName) {
    $patterns += @{ name = '/port <nic-name>';                  scope = @('/port', $nicName) }
    $patterns += @{ name = '/switch /port <nic-name>';          scope = @('/switch', $vfpSwitchId, '/port', $nicName) }
}
if ($vmId) {
    $patterns += @{ name = '/vm /port <port-id>';               scope = @('/vm', $vmId, '/port', $vfpPortName) }
    $patterns += @{ name = '/switch /vm /port <port-id>';       scope = @('/switch', $vfpSwitchId, '/vm', $vmId, '/port', $vfpPortName) }
    if ($nicName) {
        $patterns += @{ name = '/vm /port <nic-name>';          scope = @('/vm', $vmId, '/port', $nicName) }
    }
}

$workingScope = $null
$workingPatternName = $null
foreach ($p in $patterns) {
    $out = Invoke-Vfpctrl -VfpPath $vfpPath -Args ($p.scope + @('/get-port-state'))
    if (-not (Test-VfpFailure $out)) {
        $workingScope = $p.scope
        $workingPatternName = $p.name
        Save-Dump "vfpctrl /get-port-state via '$($p.name)'" $out
        Add-Result 'VFP per-port pattern' 'PASS' $p.name
        break
    } else {
        Add-Result '  pattern probe' 'INFO' "$($p.name) -- rejected"
    }
}

if (-not $workingScope) {
    Add-Result 'VFP per-port pattern' 'FAIL' 'no /port-modifier ordering accepted /get-port-state -- vfpctrl per-port commands appear unsupported on this build'
    if ($ownProbe -and -not $KeepProbe) { & docker rm -f $ContainerId 2>$null | Out-Null }
    exit 1
}

# Update $vfpScope to the discovered working pattern. Subsequent code uses
# $vfpScope as the modifier prefix for every per-port vfpctrl call.
$vfpScope = $workingScope

# ---------------------------------------------------------------------------

Section 'Baseline'

$baseGw    = Test-ContainerPing -Cid $ContainerId -Target $gateway
$baseAllow = Test-ContainerPing -Cid $ContainerId -Target $AllowIp
$baseHost  = Test-HostPing -Target $gateway

Add-Result "baseline container -> gateway ($gateway)" $(if ($baseGw -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $baseGw
Add-Result "baseline container -> $AllowIp"           $(if ($baseAllow -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $baseAllow
Add-Result "baseline host -> gateway"                  $(if ($baseHost -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $baseHost

if ($baseGw -ne 'REACHABLE') {
    Add-Result 'baseline gate' 'FAIL' 'container cannot ping gateway at baseline -- VFP test would be inconclusive'
    if ($ownProbe -and -not $KeepProbe) { & docker rm -f $ContainerId 2>$null | Out-Null }
    exit 1
}

# ---------------------------------------------------------------------------

Section 'Apply VFP rule'

# Layer / group / rule IDs are unique-per-spike-run so they cannot collide with
# Docker's own VFP entries. The layer is added at priority 1 (highest) with the
# default-allow flag set, so non-matching packets continue through to Docker's
# layers below it.
$layerId = "cwc-spike-acl-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$groupId = "cwc-spike-block-out"
$ruleId  = "cwc-spike-block-rule"

$applied = $false
$layerAdded = $false; $groupAdded = $false; $ruleAdded = $false

# $vfpScope was set in the probe above to whichever modifier ordering this
# Windows build accepts. Reuse it for every per-port vfpctrl call.

# /add-layer "[id] [name] [stateful|stateless] [priority] [flags]"
#   flags: 1=default allow, 2=hairpin, 4=clear TNI, 16=monitoring ping responder
$out = Invoke-Vfpctrl -VfpPath $vfpPath -Args ($vfpScope + @('/force-add-layer', "$layerId $layerId stateless 1 1"))
Save-Dump 'add-layer output' $out
if (Test-VfpFailure $out) {
    Add-Result 'add-layer' 'FAIL' 'vfpctrl rejected /force-add-layer -- see dump'
} else {
    Add-Result 'add-layer' 'PASS' "id=$layerId pri=1 stateless default-allow"
    $layerAdded = $true
}

# /add-group "[id] [name] [in|out|inv6|outv6] [priority]"
if ($layerAdded) {
    $out = Invoke-Vfpctrl -VfpPath $vfpPath -Args ($vfpScope + @('/layer', $layerId, '/add-group', "$groupId $groupId out 1"))
    Save-Dump 'add-group output' $out
    if (Test-VfpFailure $out) {
        Add-Result 'add-group' 'FAIL' 'vfpctrl rejected /add-group -- see dump'
    } else {
        Add-Result 'add-group' 'PASS' "id=$groupId direction=out"
        $groupAdded = $true
    }
}

# /add-rule-ex "[id] [name] [proto] [src_ip] [src_prt] [dest_ip] [dest_prt] [flag] [ttl] [pri] [type] [data]"
#   proto 256 = any
#   flag  1   = terminating
#   type  block
if ($groupAdded) {
    $ruleSpec = "$ruleId $ruleId 256 * 0 $BlockedRange 0 1 0 $Priority block"
    $out = Invoke-Vfpctrl -VfpPath $vfpPath -Args ($vfpScope + @('/layer', $layerId, '/group', $groupId, '/add-rule-ex', $ruleSpec))
    Save-Dump 'add-rule-ex output' $out
    if (Test-VfpFailure $out) {
        Add-Result 'add-rule-ex' 'FAIL' 'vfpctrl rejected /add-rule-ex -- see dump'
    } else {
        Add-Result 'add-rule-ex' 'PASS' "block proto=any dest=$BlockedRange pri=$Priority"
        $ruleAdded = $true
        $applied = $true
    }
}

# ---------------------------------------------------------------------------

$result = @{}
$lifecycle = @{}

try {
    if ($applied) {
        Section 'Verify (immediately after apply)'

        Start-Sleep -Seconds 2
        $afterGw    = Test-ContainerPing -Cid $ContainerId -Target $gateway
        $afterAllow = Test-ContainerPing -Cid $ContainerId -Target $AllowIp
        $afterHost  = Test-HostPing -Target $gateway

        $blockOk = ($afterGw    -eq 'BLOCKED')
        $allowOk = ($afterAllow -eq 'REACHABLE')
        $hostOk  = ($afterHost  -eq 'REACHABLE')

        Add-Result "container -> gateway (should BLOCK)"  $(if ($blockOk) { 'PASS' } else { 'FAIL' }) $afterGw
        Add-Result "container -> $AllowIp (should REACH)" $(if ($allowOk) { 'PASS' } else { 'FAIL' }) $afterAllow
        Add-Result "host -> gateway (regression)"         $(if ($hostOk)  { 'PASS' } else { 'FAIL' }) $afterHost

        $result['immediate'] = @{ blocked = $blockOk; allowed = $allowOk; hostOk = $hostOk }

        # ---- Lifecycle: docker stop + start ----
        # VFP ports are typically destroyed on container stop, so we expect the
        # rule NOT to survive. Confirming this informs the design: a v2 layer
        # applying via vfpctrl must re-apply on every container start.
        if ($blockOk -and $ownProbe) {
            Section 'Lifecycle: docker stop + start'

            try {
                & docker stop -t 2 $ContainerId 2>$null | Out-Null
                Start-Sleep -Seconds 2
                & docker start $ContainerId 2>$null | Out-Null
                Start-Sleep -Seconds 4
                Add-Result 'docker stop + start' 'PASS' ''
            } catch {
                Add-Result 'docker stop + start' 'FAIL' $_.Exception.Message
            }

            # Re-resolve endpoint and port (likely changed).
            $info2 = & docker inspect $ContainerId 2>$null | ConvertFrom-Json
            $ip2  = $info2[0].NetworkSettings.Networks.nat.IPAddress
            $mac2 = $info2[0].NetworkSettings.Networks.nat.MacAddress
            $gw2  = $info2[0].NetworkSettings.Networks.nat.Gateway
            $ep2  = Find-MatchingEndpoint -Ip $ip2 -Mac $mac2
            $port2 = if ($ep2) { $ep2.AdditionalParams.SwitchPortId } else { $null }

            if ($port2) {
                Add-Result 'endpoint+port re-match' 'PASS' "port=$port2 (was $vfpPortName)"
                $portChanged = ($port2 -ne $vfpPortName)
                # Re-resolve the switch GUID too in case Docker rebuilt the network.
                $switch2 = $null
                try {
                    $hnsNet2 = Get-HnsNetwork -Id $ep2.VirtualNetwork
                    if ($hnsNet2) { $switch2 = $hnsNet2.SwitchGuid }
                } catch {}
                if (-not $switch2 -and $ep2.AdditionalParams -and $ep2.AdditionalParams.SwitchId) {
                    $switch2 = $ep2.AdditionalParams.SwitchId
                }
                if (-not $switch2) { $switch2 = $vfpSwitchId }

                # Try to query whether our layer survived (it lives on the OLD port,
                # which is gone if a new port was created). On the new port, it
                # should NOT be present unless something carried it over.
                $listLayers = Invoke-Vfpctrl -VfpPath $vfpPath -Args @('/switch', $switch2, '/port', $port2, '/list-layer')
                $persists = ($listLayers -match [regex]::Escape($layerId))

                $postGw = Test-ContainerPing -Cid $ContainerId -Target $gw2
                $survived = ($postGw -eq 'BLOCKED')
                Add-Result 'block survives stop+start (effect)' $(if ($survived) { 'PASS' } elseif (-not $portChanged) { 'WARN' } else { 'INFO' }) "$postGw / layer present on (post-restart) port: $persists / port-changed: $portChanged"
                $lifecycle['stop_start'] = @{ port_changed = $portChanged; layer_present_on_post_port = $persists; effect_survives = $survived }

                # Update so cleanup targets the new port and switch.
                $matchedEndpoint = $ep2
                $vfpPortName = $port2
                $vfpSwitchId = $switch2
                $vfpScope = @('/switch', $vfpSwitchId, '/port', $vfpPortName)
                $gateway = $gw2
            } else {
                Add-Result 'endpoint+port re-match' 'WARN' 'no endpoint found after restart'
                $lifecycle['stop_start'] = @{ note = 'endpoint resolution failed' }
            }
        }
    }
}
finally {
    Section 'Cleanup'

    if ($layerAdded -and -not $KeepRule) {
        # /remove-layer cleans the layer plus all groups+rules within it.
        $out = Invoke-Vfpctrl -VfpPath $vfpPath -Args ($vfpScope + @('/layer', $layerId, '/remove-layer'))
        Save-Dump 'remove-layer output' $out
        if (Test-VfpFailure $out) {
            Add-Result 'remove-layer' 'WARN' 'vfpctrl reported failure -- layer may be on a different port (post-restart) or already gone'
        } else {
            Add-Result 'remove-layer' 'PASS' ''
        }

        Start-Sleep -Seconds 1
        $afterRemove = Test-ContainerPing -Cid $ContainerId -Target $gateway
        $cleanupOk   = ($afterRemove -eq 'REACHABLE')
        Add-Result 'gateway reachable after layer removal' $(if ($cleanupOk) { 'PASS' } else { 'FAIL' }) $afterRemove
    } elseif ($layerAdded) {
        Add-Result 'rule retained' 'INFO' '-KeepRule passed; layer left in place'
    }

    if ($ownProbe -and -not $KeepProbe) {
        & docker rm -f $ContainerId 2>$null | Out-Null
        Add-Result 'probe container remove' 'PASS' ''
    } elseif ($ownProbe) {
        Add-Result 'probe container retained' 'INFO' "$ContainerId left running (-KeepProbe)"
    }
}

# ---------------------------------------------------------------------------

Section 'Verdict'

$pass = ($script:results | Where-Object Status -eq 'PASS').Count
$fail = ($script:results | Where-Object Status -eq 'FAIL').Count
Write-Host ("  PASS: {0}" -f $pass) -ForegroundColor Green
Write-Host ("  FAIL: {0}" -f $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'DarkGray' })

$immediate = $result['immediate']
$cleanWin = $applied -and $immediate -and $immediate.blocked -and $immediate.allowed -and $immediate.hostOk

$verdict = if (-not $applied) {
    'NO-GO -- vfpctrl rejected the rule construction (layer / group / rule add). Inspect the output dumps for syntax errors specific to this Windows build.'
} elseif ($cleanWin) {
    'GO -- VFP rule blocks the gateway, allow target reachable, host unaffected. This is the host-side enforcement path. The lifecycle gotcha (rule does not survive container restart) is documented; v2 must re-apply on each container start.'
} else {
    'INVESTIGATE -- VFP rule applied but did not produce a clean win. Same enforcement gap as HNS POST in spike 4 would mean host-side enforcement on Docker Desktop is not viable from a script. Examine the per-step results.'
}

Write-Host ''
Write-Host "  Verdict: $verdict" -ForegroundColor Yellow
Write-Host ''

Write-Host 'Notes for follow-up:' -ForegroundColor DarkGray
Write-Host "  - VFP port (final):         $vfpPortName"
Write-Host "  - Layer Id:                 $layerId"
Write-Host "  - Apply (full chain):       $applied"
if ($immediate) {
    Write-Host "  - Immediate block:          $($immediate.blocked)"
    Write-Host "  - Immediate allow:          $($immediate.allowed)"
    Write-Host "  - Host unaffected:          $($immediate.hostOk)"
}
if ($lifecycle.ContainsKey('stop_start')) {
    $ls = $lifecycle['stop_start']
    Write-Host "  - stop+start port changed:  $($ls.port_changed)"
    Write-Host "  - layer present post-port:  $($ls.layer_present_on_post_port)"
    Write-Host "  - effect survives restart:  $($ls.effect_survives)"
}
Write-Host ''

if ($fail -gt 0) { exit 1 } else { exit 0 }
