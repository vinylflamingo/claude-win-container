# Spike 4: empirically test whether a host-side egress block applied as an HNS
# endpoint ACL works on a Docker Desktop Windows container.
#
# Spike 3 (hns-vfp-discovery.ps1) established the prerequisites:
#   - The HNS PowerShell module is reachable on the host.
#   - The HNS endpoint corresponding to a running container has empty .Policies
#     (Docker writes none for plain nat-attached containers, so an ACL added by
#     us has no Docker-managed sibling to collide with).
#   - $matchedEndpoint.AdditionalParams.SwitchPortId is the deterministic VFP port.
#
# This spike performs the mutation. Hypotheses:
#   H1: Adding an ACL policy with
#         Type=ACL Action=Block Direction=Out RuleType=Switch
#         RemoteAddresses=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
#       to the container's HNS endpoint blocks container egress to RFC1918
#       destinations.
#   H2: Public-internet egress (1.1.1.1) is unaffected.
#   H3: Host egress to the gateway is unaffected (no host-side regression).
#   H4: Removing the policy restores RFC1918 reachability.
#   H5: docker stop + docker start either preserves the policy (great for v2) or
#       drops it (we'd need re-apply on each container start).
#   H6: docker network disconnect/connect either preserves or drops it.
#
# The probe target inside the blocked range is the container's own gateway, since
# that is the only RFC1918 destination reliably reachable from a default-nat
# container at baseline. ICMP ping (Test-Connection) is used because the gateway
# typically does not have an open TCP listener but does answer pings.
#
# Run AS ADMINISTRATOR. Spawns a probe container (hyperv isolation,
# servercore:ltsc2019). Cleans up the ACL and the container on exit unless
# -KeepPolicy / -KeepProbe is passed.
#
# Verdict legend:
#   GO          -- ACL blocks RFC1918, allow target reachable, host unaffected,
#                  removal restores. Move on to spike 5 (vfpctrl path) and
#                  Phase 4 lifecycle integration.
#   INVESTIGATE -- partial: blocks but over-blocks; or blocks but doesn't survive
#                  a docker restart we expected it to; or some lifecycle edge
#                  case is broken. Documented but not a stop-ship.
#   NO-GO       -- the ACL has no effect, or applying it breaks Docker's own
#                  endpoint management. Pivot to spike 5 only or to alternatives.
#
# Usage:
#   .\tests\spikes\hns-acl-block.ps1
#   .\tests\spikes\hns-acl-block.ps1 -KeepProbe                  # leave probe container running
#   .\tests\spikes\hns-acl-block.ps1 -KeepPolicy                 # leave the ACL applied (DANGER: container will be partly broken)
#   .\tests\spikes\hns-acl-block.ps1 -ContainerId <existing-id>  # use existing container

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ContainerId,
    [string]$Image = 'mcr.microsoft.com/windows/servercore:ltsc2019',
    [string]$BlockedRanges = '10.0.0.0/8,172.16.0.0/12,192.168.0.0/16',
    [string]$AllowIp = '1.1.1.1',
    [int]$Priority = 100,
    [switch]$KeepProbe,
    [switch]$KeepPolicy
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

function Build-AclPolicy {
    param([string]$RemoteAddresses, [int]$Priority)
    return @{
        Type            = 'ACL'
        Id              = "cwc-spike-acl-$([guid]::NewGuid().ToString())"
        Action          = 'Block'
        Direction       = 'Out'
        RuleType        = 'Switch'
        Priority        = $Priority
        Protocols       = '256'   # 256 == any protocol
        RemoteAddresses = $RemoteAddresses
    }
}

# Apply / remove via Invoke-HNSRequest. The HNS HTTP-style API exposes
# ApplyPolicy and RemovePolicy actions on /endpoints/{id}; the request body
# carries a Policies array. This is the path used by Microsoft's k8s on
# Windows scripts in microsoft/SDN -- if the loaded HNS module doesn't expose
# Invoke-HNSRequest we abort with a diagnostic.
function Invoke-EndpointPolicyAction {
    param(
        [Parameter(Mandatory)] [ValidateSet('ApplyPolicy', 'RemovePolicy')] [string]$Action,
        [Parameter(Mandatory)] [string]$EndpointId,
        [Parameter(Mandatory)] $Policy
    )
    $payload = @{ Policies = @($Policy) } | ConvertTo-Json -Depth 10 -Compress
    return Invoke-HNSRequest -Method POST -Type endpoints -Id $EndpointId -Action $Action -Data $payload
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
    Add-Result 'HNS module' 'FAIL' 'Get-HnsEndpoint not available -- run hns-vfp-discovery.ps1 first for setup notes'
    exit 1
}
Add-Result 'HNS module' 'PASS' 'Get-HnsEndpoint available'

# Diagnose what's actually loaded. This helps when a future Windows / DD update
# changes which HNS module variant ships and the spike has to adapt.
$loadedHnsModules = @(Get-Module | Where-Object { $_.ExportedCommands.Keys -contains 'Get-HnsEndpoint' })
foreach ($m in $loadedHnsModules) {
    Add-Result '  HNS source' 'INFO' "name=$($m.Name) path=$($m.Path)"
    $exported = @($m.ExportedCommands.Keys) | Sort-Object
    Add-Result '  HNS cmdlets' 'INFO' ($exported -join ', ')
}

# Invoke-HNSRequest is exported by microsoft/SDN's hns.psm1 but NOT by the
# Microsoft-shipped HostNetworkingService module. When missing, define it inline
# via P/Invoke into vmcompute.dll's HNSCall. Schema cribbed from microsoft/SDN
# (MIT-licensed). This keeps the spike self-contained -- no manual third-party
# install required to run it.
$hnsRequestSource = $null
if (Get-Command Invoke-HNSRequest -ErrorAction SilentlyContinue) {
    $hnsRequestSource = 'module'
} else {
    if (-not ('CwcSpike.Hns.NativeMethods' -as [type])) {
        $sig = @'
[DllImport("vmcompute.dll", CharSet = CharSet.Unicode)]
public static extern void HNSCall(
    [MarshalAs(UnmanagedType.LPWStr)] string method,
    [MarshalAs(UnmanagedType.LPWStr)] string path,
    [MarshalAs(UnmanagedType.LPWStr)] string request,
    [MarshalAs(UnmanagedType.LPWStr)] out string response);
'@
        try {
            Add-Type -MemberDefinition $sig -Namespace 'CwcSpike.Hns' -Name 'NativeMethods' -ErrorAction Stop | Out-Null
        } catch {
            Add-Result 'Invoke-HNSRequest fallback' 'FAIL' "Add-Type vmcompute.dll: $($_.Exception.Message)"
            exit 1
        }
    }

    function global:Invoke-HNSRequest {
        param(
            [ValidateSet('GET', 'POST', 'DELETE')]
            [Parameter(Mandatory)] [string]$Method,
            [Parameter(Mandatory)] [string]$Type,
            [string]$Action,
            [string]$Data,
            [Guid]$Id = [Guid]::Empty
        )
        $hnsPath = "/$Type"
        if ($Id -ne [Guid]::Empty) { $hnsPath += "/$Id" }
        if ($Action) { $hnsPath += "/$Action" }
        $body = if ($Data) { $Data } else { '' }
        $response = ''
        [CwcSpike.Hns.NativeMethods]::HNSCall($Method, $hnsPath, $body, [ref] $response)
        if ($response) {
            $obj = $response | ConvertFrom-Json
            if ($obj.PSObject.Properties.Match('Error').Count -gt 0 -and $obj.Error) {
                throw "HNS error: $($obj.Error)"
            }
            if ($obj.PSObject.Properties.Match('Output').Count -gt 0) { return $obj.Output }
            return $obj
        }
        return $null
    }
    $hnsRequestSource = 'inlined (P/Invoke vmcompute.dll!HNSCall)'
}
Add-Result 'Invoke-HNSRequest' 'PASS' "via $hnsRequestSource"

# HCN P/Invoke setup. computenetwork.dll exposes the modern HostComputeNetwork
# API that production CNI plugins on Windows use. HcnModifyEndpoint is the
# documented path for adding endpoint policies post-creation; unlike HNS's
# metadata-only POST it is supposed to trigger VFP reconciliation. We define
# just what we need: open / modify / close endpoint, plus a kernel32 LocalFree
# for the error-record allocation.
$hcnAvailable = $false
if (Test-Path "$env:WINDIR\System32\computenetwork.dll") {
    if (-not ('CwcSpike.Hcn.NativeMethods' -as [type])) {
        $hcnSig = @'
[DllImport("computenetwork.dll", CharSet = CharSet.Unicode)]
public static extern int HcnOpenEndpoint(
    ref System.Guid Id,
    out System.IntPtr Endpoint,
    out System.IntPtr ErrorRecord);

[DllImport("computenetwork.dll", CharSet = CharSet.Unicode)]
public static extern int HcnModifyEndpoint(
    System.IntPtr Endpoint,
    [MarshalAs(UnmanagedType.LPWStr)] string SettingsJson,
    out System.IntPtr ErrorRecord);

[DllImport("computenetwork.dll", CharSet = CharSet.Unicode)]
public static extern int HcnCloseEndpoint(System.IntPtr Endpoint);

[DllImport("kernel32.dll")]
public static extern System.IntPtr LocalFree(System.IntPtr hMem);

public static string ReadAndFreeWideString(System.IntPtr ptr) {
    if (ptr == System.IntPtr.Zero) return null;
    try { return System.Runtime.InteropServices.Marshal.PtrToStringUni(ptr); }
    finally { LocalFree(ptr); }
}
'@
        try {
            Add-Type -MemberDefinition $hcnSig -Namespace 'CwcSpike.Hcn' -Name 'NativeMethods' -ErrorAction Stop | Out-Null
            $hcnAvailable = $true
        } catch {
            Add-Result 'HCN P/Invoke' 'WARN' "Add-Type failed: $($_.Exception.Message)"
        }
    } else {
        $hcnAvailable = $true
    }
}
if ($hcnAvailable) {
    Add-Result 'HCN P/Invoke' 'PASS' 'computenetwork.dll bound (HcnOpen/Modify/CloseEndpoint)'
} elseif (Test-Path "$env:WINDIR\System32\computenetwork.dll") {
    # already warned above
} else {
    Add-Result 'HCN P/Invoke' 'WARN' 'computenetwork.dll not present -- HCN variant will be skipped'
}

function Invoke-HcnEndpointPolicyChange {
    param(
        [Parameter(Mandatory)] [string]$EndpointId,
        [Parameter(Mandatory)] [ValidateSet('Add', 'Remove', 'Update')] [string]$RequestType,
        [Parameter(Mandatory)] $Policy
    )
    # HCN uses a nested EndpointPolicy schema: Type at the outer level, Settings
    # as an inner object holding the actual ACL fields. Different from HNS's flat
    # schema which puts everything at the top level. The ResourceType/RequestType/
    # Settings envelope is the documented modify-endpoint request shape.
    $hcnPolicy = @{
        Type     = 'ACL'
        Settings = @{
            Action          = $Policy.Action
            Direction       = $Policy.Direction
            Protocols       = $Policy.Protocols
            Priority        = $Policy.Priority
            RemoteAddresses = $Policy.RemoteAddresses
        }
    }
    $request = @{
        ResourceType = 'Policy'
        RequestType  = $RequestType
        Settings     = @{ Policies = @($hcnPolicy) }
    }
    $json = $request | ConvertTo-Json -Depth 10 -Compress

    $guid   = [Guid]::Parse($EndpointId)
    $handle = [System.IntPtr]::Zero
    $errPtr = [System.IntPtr]::Zero
    $hr = [CwcSpike.Hcn.NativeMethods]::HcnOpenEndpoint([ref]$guid, [ref]$handle, [ref]$errPtr)
    if ($hr -ne 0) {
        $errMsg = [CwcSpike.Hcn.NativeMethods]::ReadAndFreeWideString($errPtr)
        throw "HcnOpenEndpoint failed: HR=0x$($hr.ToString('X8')) error=$errMsg"
    }
    try {
        $hr = [CwcSpike.Hcn.NativeMethods]::HcnModifyEndpoint($handle, $json, [ref]$errPtr)
        if ($hr -ne 0) {
            $errMsg = [CwcSpike.Hcn.NativeMethods]::ReadAndFreeWideString($errPtr)
            throw "HcnModifyEndpoint($RequestType) failed: HR=0x$($hr.ToString('X8')) error=$errMsg"
        }
        return @{ Method = 'HcnModifyEndpoint'; RequestType = $RequestType; HResult = 0 }
    } finally {
        [CwcSpike.Hcn.NativeMethods]::HcnCloseEndpoint($handle) | Out-Null
    }
}

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
    # NOTE: NOT --rm. We need the container to survive docker stop/start for the
    # lifecycle probe; we delete it explicitly in Cleanup.
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

$containerIp  = $null
$containerMac = $null
$gateway      = $null
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

if (-not $gateway) {
    Add-Result 'gateway resolve' 'FAIL' 'no gateway from docker inspect; cannot pick a probe target inside RFC1918'
    exit 1
}

$matchedEndpoint = Find-MatchingEndpoint -Ip $containerIp -Mac $containerMac
if (-not $matchedEndpoint) {
    Add-Result 'endpoint match' 'FAIL' "no HNS endpoint matched ip=$containerIp mac=$containerMac"
    exit 1
}
Add-Result 'endpoint match' 'PASS' "Id=$($matchedEndpoint.Id)"

# ---------------------------------------------------------------------------

Section 'Baseline'

$baseGw   = Test-ContainerPing -Cid $ContainerId -Target $gateway
$baseAllow = Test-ContainerPing -Cid $ContainerId -Target $AllowIp
$baseHost = Test-HostPing -Target $gateway

Add-Result "baseline container -> gateway ($gateway)"     $(if ($baseGw -eq 'REACHABLE') { 'PASS' } else { 'WARN' })  $baseGw
Add-Result "baseline container -> $AllowIp"               $(if ($baseAllow -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $baseAllow
Add-Result "baseline host -> gateway"                     $(if ($baseHost -eq 'REACHABLE') { 'PASS' } else { 'WARN' }) $baseHost

if ($baseGw -ne 'REACHABLE') {
    Add-Result 'baseline gate' 'FAIL' 'container cannot ping gateway at baseline -- ACL test would be inconclusive'
    if ($ownProbe -and -not $KeepProbe) {
        & docker rm -f $ContainerId 2>$null | Out-Null
    }
    exit 1
}

# ---------------------------------------------------------------------------

Section 'Apply ACL'

$policy = Build-AclPolicy -RemoteAddresses $BlockedRanges -Priority $Priority
Save-Dump 'policy payload (flat HNS schema)' $policy

# HNS / HCN have shipped several request shapes for adding endpoint policies.
# microsoft/SDN's hns.psm1 documents ApplyPolicy as the canonical action, but
# different Windows builds and module variants (HostNetworkingService vs SDN
# vs k8s-on-Windows) accept different request shapes. We try several in order
# and stop on the first one that both succeeds at the API level AND results in
# the policy actually being visible on the endpoint after a re-fetch. The
# winning variant is recorded for the design doc.
$attempts = @(
    @{
        name  = 'POST /endpoints/{id}/ApplyPolicy + flat schema'
        apply = { Invoke-HNSRequest -Method POST -Type endpoints -Id $matchedEndpoint.Id -Action 'ApplyPolicy' -Data ((@{ Policies = @($policy) } | ConvertTo-Json -Depth 10 -Compress)) }
    },
    @{
        name  = 'POST /endpoints/{id} (no action) + flat schema'
        apply = { Invoke-HNSRequest -Method POST -Type endpoints -Id $matchedEndpoint.Id -Action $null         -Data ((@{ Policies = @($policy) } | ConvertTo-Json -Depth 10 -Compress)) }
    },
    @{
        name  = 'POST /endpoints/{id}/Update + flat schema'
        apply = { Invoke-HNSRequest -Method POST -Type endpoints -Id $matchedEndpoint.Id -Action 'Update'      -Data ((@{ Policies = @($policy) } | ConvertTo-Json -Depth 10 -Compress)) }
    },
    @{
        name  = 'POST /endpoints/{id} (no action) + HCN-modify wrapper on HNS path'
        apply = { Invoke-HNSRequest -Method POST -Type endpoints -Id $matchedEndpoint.Id -Action $null         -Data ((@{ ResourceType = 1; RequestType = 0; Settings = @{ Policies = @($policy) } } | ConvertTo-Json -Depth 10 -Compress)) }
    }
)

if ($hcnAvailable) {
    $attempts += @{
        name  = 'HCN: HcnModifyEndpoint(Add) with nested EndpointPolicy schema'
        apply = { Invoke-HcnEndpointPolicyChange -EndpointId $matchedEndpoint.Id -RequestType 'Add' -Policy $policy }
    }
}

$applied      = $false
$winningName  = $null
$applyErrors  = @()

foreach ($a in $attempts) {
    try {
        $resp = & $a.apply
        Save-Dump "response: $($a.name)" $resp
    } catch {
        $applyErrors += "$($a.name): $($_.Exception.Message)"
        Add-Result '  variant rejected' 'INFO' "$($a.name) -- $($_.Exception.Message)"
        continue
    }

    Start-Sleep -Seconds 2
    # Authoritative test: does traffic actually block? On this build the HNS
    # POST variant attaches an ACL to the endpoint object but VFP does not
    # enforce it; we already know that, so visibility-on-endpoint is no longer
    # sufficient. The variant only "wins" if the container's egress to a
    # destination inside the blocked range is actually stopped.
    $check       = Get-HnsEndpoint -Id $matchedEndpoint.Id
    $visible     = @($check.Policies) | Where-Object { $_.Type -eq 'ACL' -and $_.Id -eq $policy.Id } | Select-Object -First 1
    $reachProbe  = Test-ContainerPing -Cid $ContainerId -Target $gateway
    $enforced    = ($reachProbe -eq 'BLOCKED')

    if ($enforced) {
        $applied = $true
        $winningName = $a.name
        Add-Result '  variant ENFORCES traffic block' 'PASS' "$($a.name) (acl-visible-on-endpoint=$([bool]$visible))"
        Save-Dump 'endpoint .Policies (post-apply)' $check.Policies
        break
    } elseif ($visible) {
        # The classic gap: API succeeded, ACL is in the endpoint object, but
        # VFP didn't reload its rules. Note and continue to the next variant.
        # (We leave the metadata-only ACL in place; subsequent variants will
        # add their own. They're harmless until cleanup runs.)
        $applyErrors += "$($a.name): metadata-only -- ACL visible on endpoint but no traffic effect"
        Add-Result '  variant metadata-only (visible, not enforced)' 'INFO' $a.name
    } else {
        # Call returned without throwing but the ACL is invisible AND not
        # enforcing. The API tolerated the request without doing anything we
        # can observe.
        $applyErrors += "$($a.name): silent no-op (no visible policy + no traffic effect)"
        Add-Result '  variant silent no-op' 'INFO' $a.name
    }
}

if (-not $applied) {
    Add-Result 'ApplyPolicy (any variant)' 'FAIL' 'none of the variants resulted in the ACL being attached to the endpoint'
    foreach ($e in $applyErrors) {
        Add-Result '  detail' 'INFO' $e
    }
}

# ---------------------------------------------------------------------------

$blockResults = @{}
$lifecycle    = @{}

try {
    if ($applied) {
        Section 'Verify (immediately after apply)'

        Start-Sleep -Seconds 2  # let the policy propagate
        $afterGw    = Test-ContainerPing -Cid $ContainerId -Target $gateway
        $afterAllow = Test-ContainerPing -Cid $ContainerId -Target $AllowIp
        $afterHost  = Test-HostPing -Target $gateway

        $blockOk     = ($afterGw    -eq 'BLOCKED')
        $allowOk     = ($afterAllow -eq 'REACHABLE')
        $hostOk      = ($afterHost  -eq 'REACHABLE')

        Add-Result "container -> gateway (should BLOCK)"  $(if ($blockOk) { 'PASS' } else { 'FAIL' }) $afterGw
        Add-Result "container -> $AllowIp (should REACH)" $(if ($allowOk) { 'PASS' } else { 'FAIL' }) $afterAllow
        Add-Result "host -> gateway (regression)"         $(if ($hostOk)  { 'PASS' } else { 'FAIL' }) $afterHost

        $blockResults['immediate'] = @{ blocked = $blockOk; allowed = $allowOk; hostOk = $hostOk }

        # ---- Lifecycle: docker stop + start ----
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

            # Endpoint Id may change after restart -- re-resolve.
            $info2 = & docker inspect $ContainerId 2>$null | ConvertFrom-Json
            $ip2  = $info2[0].NetworkSettings.Networks.nat.IPAddress
            $mac2 = $info2[0].NetworkSettings.Networks.nat.MacAddress
            $gw2  = $info2[0].NetworkSettings.Networks.nat.Gateway
            $ep2  = Find-MatchingEndpoint -Ip $ip2 -Mac $mac2
            if ($ep2) {
                Add-Result 'endpoint re-match (post-restart)' 'PASS' "Id=$($ep2.Id) (was $($matchedEndpoint.Id))"
                Save-Dump 'endpoint .Policies (post-restart)' $ep2.Policies
                $stillThere = @($ep2.Policies) | Where-Object { $_.Type -eq 'ACL' -and $_.Action -eq 'Block' } | Select-Object -First 1
                $persists = [bool]$stillThere

                $postGw = Test-ContainerPing -Cid $ContainerId -Target $gw2
                $survived = ($postGw -eq 'BLOCKED')
                Add-Result 'block survives stop+start (effect)' $(if ($survived) { 'PASS' } else { 'WARN' }) "$postGw / policy on endpoint: $persists"
                $lifecycle['stop_start'] = @{ persists_in_endpoint = $persists; effect_survives = $survived }

                # Track for cleanup -- if endpoint changed, we need to remove from the new one.
                $matchedEndpoint = $ep2
                $gateway = $gw2
            } else {
                Add-Result 'endpoint re-match (post-restart)' 'WARN' 'no endpoint matched after restart -- container may have been re-IPed'
                $lifecycle['stop_start'] = @{ persists_in_endpoint = $null; effect_survives = $null; note = 'endpoint re-resolution failed' }
            }
        }

        # ---- Lifecycle: docker network disconnect / connect ----
        # Skipped by default -- disconnect+connect typically rotates the endpoint
        # entirely, making this functionally equivalent to a restart from the
        # ACL's perspective. Left as a TODO that a follow-up spike could probe
        # if we discover surprising behaviour during stop/start.
        $lifecycle['disconnect_connect'] = @{ skipped = $true; reason = 'rotates endpoint -- behaviour same as stop+start at ACL level' }
    }
}
finally {
    Section 'Cleanup'

    if ($applied -and -not $KeepPolicy) {
        # Cleanup is tried as a sequence of variants for the same reason apply was:
        # the symmetric remove for the apply variant that worked may not be
        # ApplyPolicy/RemovePolicy. We stop on the first variant whose effect
        # restores container-to-gateway reachability (the authoritative test) or
        # at minimum strips the ACL from the HNS endpoint object.
        $cleanupAttempts = @(
            @{ name = 'POST /endpoints/{id}/RemovePolicy';   apply = { Invoke-HNSRequest -Method POST -Type endpoints -Id $matchedEndpoint.Id -Action 'RemovePolicy' -Data ((@{ Policies = @($policy) } | ConvertTo-Json -Depth 10 -Compress)) } },
            @{ name = 'POST /endpoints/{id} clear policies'; apply = { Invoke-HNSRequest -Method POST -Type endpoints -Id $matchedEndpoint.Id -Action $null          -Data ((@{ Policies = @() } | ConvertTo-Json -Depth 10 -Compress)) } },
            @{ name = 'POST /endpoints/{id} HCN remove (HNS path)'; apply = { Invoke-HNSRequest -Method POST -Type endpoints -Id $matchedEndpoint.Id -Action $null  -Data ((@{ ResourceType = 1; RequestType = 2; Settings = @{ Policies = @($policy) } } | ConvertTo-Json -Depth 10 -Compress)) } }
        )
        if ($hcnAvailable) {
            $cleanupAttempts += @{
                name  = 'HCN: HcnModifyEndpoint(Remove)'
                apply = { Invoke-HcnEndpointPolicyChange -EndpointId $matchedEndpoint.Id -RequestType 'Remove' -Policy $policy }
            }
        }
        $cleaned = $false
        foreach ($c in $cleanupAttempts) {
            try {
                & $c.apply | Out-Null
            } catch {
                Add-Result '  remove variant rejected' 'INFO' "$($c.name) -- $($_.Exception.Message)"
                continue
            }
            Start-Sleep -Seconds 1
            $check = Get-HnsEndpoint -Id $matchedEndpoint.Id -ErrorAction SilentlyContinue
            $still = @($check.Policies) | Where-Object { $_.Id -eq $policy.Id }
            $reach = Test-ContainerPing -Cid $ContainerId -Target $gateway
            if (-not $still -or $reach -eq 'REACHABLE') {
                Add-Result 'remove variant accepted' 'PASS' "$($c.name) (acl-on-endpoint=$([bool]$still) reach=$reach)"
                $cleaned = $true
                break
            } else {
                Add-Result '  remove variant tolerated, ACL still present + still blocked' 'INFO' $c.name
            }
        }
        if (-not $cleaned) {
            Add-Result 'cleanup' 'FAIL' "could not remove ACL via any variant -- ACL $($policy.Id) is still on endpoint $($matchedEndpoint.Id)"
        }

        Start-Sleep -Seconds 1
        $afterRemove = Test-ContainerPing -Cid $ContainerId -Target $gateway
        $cleanupOk   = ($afterRemove -eq 'REACHABLE')
        Add-Result 'gateway reachable after policy removal' $(if ($cleanupOk) { 'PASS' } else { 'FAIL' }) $afterRemove

        $endpointFinal = Get-HnsEndpoint -Id $matchedEndpoint.Id -ErrorAction SilentlyContinue
        if ($endpointFinal) {
            Save-Dump 'endpoint .Policies (post-remove)' $endpointFinal.Policies
        }
    } elseif ($applied) {
        Add-Result 'policy retained' 'INFO' '-KeepPolicy passed; ACL left applied'
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

$immediate = $blockResults['immediate']
$cleanWin = $applied -and $immediate -and $immediate.blocked -and $immediate.allowed -and $immediate.hostOk

$verdict = if (-not $applied) {
    'NO-GO via HNS module path -- none of the request-shape variants resulted in the ACL being attached to the endpoint. Next step is HCN P/Invoke (HcnModifyEndpoint via computenetwork.dll), which is the modern Microsoft-supported path. The variant attempts and HNS error messages above tell us which paths the loaded HNS service rejects -- carry that into the HCN follow-up.'
} elseif ($cleanWin) {
    "GO via '$winningName'. ACL blocks RFC1918, allow target reachable, host unaffected. Move on to spike 5 (vfpctrl path comparison) and Phase 4 lifecycle integration. Lifecycle probe data captured."
} else {
    "INVESTIGATE -- ACL applied via '$winningName' but did not produce a clean win. Review the per-step results: check whether block worked, allow stayed reachable, and host was unaffected."
}

Write-Host ''
Write-Host "  Verdict: $verdict" -ForegroundColor Yellow
Write-Host ''

Write-Host 'Notes for follow-up:' -ForegroundColor DarkGray
Write-Host "  - Endpoint Id (final):   $(if ($matchedEndpoint) { $matchedEndpoint.Id })"
Write-Host "  - Apply succeeded:       $applied"
Write-Host "  - Winning variant:       $(if ($winningName) { $winningName } else { '(none)' })"
if ($immediate) {
    Write-Host "  - Immediate block:       $($immediate.blocked)"
    Write-Host "  - Immediate allow:       $($immediate.allowed)"
    Write-Host "  - Host unaffected:       $($immediate.hostOk)"
}
if ($lifecycle.ContainsKey('stop_start')) {
    $ls = $lifecycle['stop_start']
    Write-Host "  - stop+start persists:   $($ls.persists_in_endpoint) (effect: $($ls.effect_survives))"
}
Write-Host ''

if ($fail -gt 0) { exit 1 } else { exit 0 }
