# Spike 3: surface the HNS / VFP state for a running Docker Desktop Windows
# container, so we know what schema a host-side enforcement layer would write into.
#
# Spikes 1 (hyperv-firewall.ps1) and 2 (host-firewall.ps1) ruled out Hyper-V
# Firewall, Hyper-V VM extended ACLs, and Defender Firewall as host-side egress
# controls for Docker Desktop containers. Docker's networking goes through HNS
# (Host Networking Service) and VFP (Virtual Filtering Platform), which sit
# below the WFP layer where Defender Firewall rules apply. HNS/VFP is the
# remaining candidate for v2 host-side enforcement (see issue #3 and
# docs/security.md "Future work" section).
#
# This spike is read-only. It does not add or remove any policies. It answers:
#   Q1: Is the HNS PowerShell module reachable on this host?
#   Q2: Is vfpctrl.exe present, and which CLI shape does it expose?
#   Q3: Can we identify the HNS endpoint that maps to a running container?
#   Q4: What policies does Docker already attach to that endpoint?
#   Q5: What VFP port does the endpoint correspond to, and what rules sit on it?
#
# The captured policy and rule dumps inform the next two spikes (hns-acl-block,
# vfp-rule-block), which are the ones that actually mutate state.
#
# Run AS ADMINISTRATOR. Spawns a one-shot probe container (hyperv isolation,
# servercore:ltsc2019) and kills it on exit unless -KeepProbe is passed. To
# inspect an existing container instead, pass -ContainerId.
#
# Verdict legend:
#   GO          -- HNS API and VFP CLI both reachable; container endpoint and VFP
#                  port identified; schema dumped. Proceed to mutate spikes.
#   INVESTIGATE -- partial: one of the two paths is unreachable from this script,
#                  or the schema is unclear. The mutate spike for the working
#                  path is still worth running.
#   NO-GO       -- neither HNS nor VFP can be reached from a host-side script.
#                  Pivot to documenting the proxy / dedicated-VM fallback.
#
# Usage:
#   .\tests\spikes\hns-vfp-discovery.ps1
#   .\tests\spikes\hns-vfp-discovery.ps1 -KeepProbe
#   .\tests\spikes\hns-vfp-discovery.ps1 -ContainerId <id>     # use existing container

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ContainerId,
    [string]$Image = 'mcr.microsoft.com/windows/servercore:ltsc2019',
    [switch]$KeepProbe
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

# Try to make the HNS module available. Multiple sources, in order of preference:
#   1. Already imported / discoverable via $env:PSModulePath.
#   2. C:\Program Files\WindowsPowerShell\Modules\HNS\*.psm1 (manual install).
#   3. C:\Program Files\WindowsPowerShell\Modules\HostNetworkingService\*.psm1.
# The HNS module is NOT bundled with Docker Desktop or Windows client SKUs by
# default. If absent, we point the user at Microsoft's published copy.
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

Section 'Environment'

$os = Get-CimInstance Win32_OperatingSystem
Add-Result 'OS' 'INFO' "$($os.Caption) build $($os.BuildNumber)"

try {
    $dockerVer = & docker version --format '{{.Server.Version}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "docker version exit $LASTEXITCODE" }
    Add-Result 'Docker daemon' 'PASS' "v$dockerVer"
} catch {
    Add-Result 'Docker daemon' 'FAIL' $_.Exception.Message
    Write-Host ''; Write-Host 'Aborting -- Docker not reachable.' -ForegroundColor Red
    exit 1
}

# Capture Docker Desktop version for the brittleness assessment in Phase 5.
try {
    $ddInfo = & docker info --format '{{json .}}' 2>$null | ConvertFrom-Json
    $ddVer = if ($ddInfo.ClientInfo.Version) { $ddInfo.ClientInfo.Version } else { '(unknown)' }
    Add-Result 'Docker Desktop client' 'INFO' "v$ddVer"
} catch {
    Add-Result 'Docker Desktop client' 'WARN' "could not parse docker info -- $($_.Exception.Message)"
}

# HNS service must be running for any of this to work.
try {
    $hnsSvc = Get-Service hns -ErrorAction Stop
    Add-Result 'HNS service' $(if ($hnsSvc.Status -eq 'Running') { 'PASS' } else { 'WARN' }) "Status=$($hnsSvc.Status)"
} catch {
    Add-Result 'HNS service' 'FAIL' $_.Exception.Message
}

# HNS PowerShell module.
$hnsLoaded = Import-HnsModuleIfPossible
if ($hnsLoaded) {
    Add-Result 'HNS PowerShell module' 'PASS' 'Get-HnsEndpoint available'
} else {
    Add-Result 'HNS PowerShell module' 'WARN' 'not on PSModulePath -- get hns.psm1 from github.com/microsoft/SDN/tree/master/Kubernetes/windows'
}

# hcsdiag.exe is an alternative inspection tool (ships with Windows containers feature).
$hasHcsDiag = [bool](Get-Command hcsdiag -ErrorAction SilentlyContinue)
Add-Result 'hcsdiag.exe' $(if ($hasHcsDiag) { 'PASS' } else { 'INFO' }) $(if ($hasHcsDiag) { 'present (informational)' } else { 'not on PATH' })

# vfpctrl.exe presence and CLI variant.
$vfpPath = $null
foreach ($p in @(
    "$env:WINDIR\System32\vfpctrl.exe",
    "$env:WINDIR\SysWOW64\vfpctrl.exe"
)) {
    if (Test-Path $p) { $vfpPath = $p; break }
}
if ($vfpPath) {
    Add-Result 'vfpctrl.exe' 'PASS' $vfpPath
    try {
        $help = & $vfpPath /? 2>&1 | Out-String
        $script:dump['vfpctrl /?'] = $help
        # CLI shape detection: Microsoft has shipped two variants. The newer one uses
        # /list-vmswitch-port; older builds used /list-port without the prefix.
        $newerCli = ($help -match '/list-vmswitch-port')
        Add-Result 'vfpctrl CLI shape' 'INFO' $(if ($newerCli) { 'newer (/list-vmswitch-port)' } else { 'older (/list-port)' })
    } catch {
        Add-Result 'vfpctrl /?' 'WARN' $_.Exception.Message
    }
} else {
    Add-Result 'vfpctrl.exe' 'FAIL' 'not found in System32 or SysWOW64'
}

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
        $cid = & docker run -d --rm --isolation=hyperv $Image powershell -NoProfile -Command 'Start-Sleep 600' 2>$null
        if (-not $cid -or $LASTEXITCODE -ne 0) { throw 'docker run failed' }
        $ContainerId = $cid.Trim()
        $ownProbe = $true
        Add-Result 'probe container start' 'PASS' "id=$($ContainerId.Substring(0,12))"
        # Endpoints don't always exist immediately after `docker run -d` returns.
        Start-Sleep -Seconds 3
    } catch {
        Add-Result 'probe container start' 'FAIL' $_.Exception.Message
        exit 1
    }
} else {
    Add-Result 'probe container' 'INFO' "using $ContainerId (caller-supplied)"
}

# docker inspect to find the container's NIC MAC + IP. We use these to match the
# container against an HNS endpoint, since the endpoint Id is not surfaced by
# docker inspect directly.
$containerMac = $null
$containerIp  = $null
try {
    $info = & docker inspect $ContainerId 2>$null | ConvertFrom-Json
    $netSettings = $info[0].NetworkSettings
    if ($netSettings.Networks.nat) {
        $containerIp  = $netSettings.Networks.nat.IPAddress
        $containerMac = $netSettings.Networks.nat.MacAddress
    } elseif ($netSettings.IPAddress) {
        $containerIp  = $netSettings.IPAddress
        $containerMac = $netSettings.MacAddress
    }
    Add-Result 'docker inspect' 'PASS' "ip=$containerIp mac=$containerMac"
} catch {
    Add-Result 'docker inspect' 'FAIL' $_.Exception.Message
}

Section 'HNS state'

$matchedEndpoint = $null
$endpoints = @()
if ($hnsLoaded) {
    try {
        $networks = Get-HnsNetwork
        Add-Result 'HnsNetwork enumerate' 'PASS' "$(@($networks).Count) network(s)"
        foreach ($n in $networks) {
            Add-Result '  network' 'INFO' "Name=$($n.Name) Type=$($n.Type) Id=$($n.Id)"
        }
        Save-Dump 'HnsNetworks (Format-List)' $networks
    } catch {
        Add-Result 'HnsNetwork enumerate' 'FAIL' $_.Exception.Message
    }

    try {
        $endpoints = Get-HnsEndpoint
        Add-Result 'HnsEndpoint enumerate' 'PASS' "$(@($endpoints).Count) endpoint(s)"
    } catch {
        Add-Result 'HnsEndpoint enumerate' 'FAIL' $_.Exception.Message
    }

    if ($endpoints -and $containerIp) {
        $matchedEndpoint = $endpoints | Where-Object { $_.IPAddress -eq $containerIp } | Select-Object -First 1
    }
    if (-not $matchedEndpoint -and $endpoints -and $containerMac) {
        $normMac = ($containerMac -replace '[:-]', '').ToUpper()
        $matchedEndpoint = $endpoints | Where-Object {
            (($_.MacAddress -replace '[:-]', '').ToUpper()) -eq $normMac
        } | Select-Object -First 1
    }

    if ($matchedEndpoint) {
        Add-Result 'endpoint match' 'PASS' "Id=$($matchedEndpoint.Id)"
        Save-Dump 'matched HnsEndpoint (full)' $matchedEndpoint
        Save-Dump 'matched HnsEndpoint .Policies' $matchedEndpoint.Policies

        # For comparison, also dump policies from a different endpoint (if any) so we
        # can see what Docker writes by default vs. what is unique to our container.
        $other = $endpoints | Where-Object { $_.Id -ne $matchedEndpoint.Id } | Select-Object -First 1
        if ($other) {
            Save-Dump 'sibling HnsEndpoint .Policies (for diff)' $other.Policies
        }
    } else {
        Add-Result 'endpoint match' 'FAIL' "no endpoint matched IP=$containerIp / MAC=$containerMac"
    }
} else {
    Add-Result 'HNS enumeration' 'WARN' 'skipped -- HNS module not loaded'
}

Section 'VFP state'

# Empirical finding from the v0.1 spike run (DD 28.2.2, Win 11 26200): the HNS
# endpoint exposes the VFP port name deterministically as
#   $matchedEndpoint.AdditionalParams.SwitchPortId
# which equals the endpoint Id (uppercased). Prefer that over substring-matching
# the /list-vmswitch-port output -- it's stable and doesn't depend on Docker's
# port-naming convention.
#
# vfpctrl CLI gotcha: modifiers (/port, /switch, /layer, /group) MUST precede the
# action verb. The argument order /list-rule /port <name> returns "file not found";
# /port <name> /list-rule works. Also: /list-port is NOT a valid action -- use
# /list-vmswitch-port (top-level) or per-port queries like /get-port-state.
$vfpPortGuid = $null
if ($vfpPath) {
    if ($matchedEndpoint -and $matchedEndpoint.AdditionalParams -and $matchedEndpoint.AdditionalParams.SwitchPortId) {
        $vfpPortGuid = $matchedEndpoint.AdditionalParams.SwitchPortId
        Add-Result 'VFP port (from HNS endpoint)' 'PASS' "guid=$vfpPortGuid"
    }

    # Always capture the full vmswitch-port list as a corpus dump (informative for
    # the design doc and a fallback if AdditionalParams.SwitchPortId is missing on
    # some DD version).
    try {
        $portList = & $vfpPath /list-vmswitch-port 2>&1 | Out-String
        Save-Dump 'vfpctrl /list-vmswitch-port' $portList

        if (-not $vfpPortGuid -and $matchedEndpoint) {
            $shortId = ($matchedEndpoint.Id -replace '[{}]', '').Substring(0,8)
            $candidate = ($portList -split "`r?`n") | Where-Object { $_ -match $shortId } | Select-Object -First 1
            if ($candidate -and $candidate -match '([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})') {
                $vfpPortGuid = $matches[1]
                Add-Result 'VFP port (substring fallback)' 'PASS' "guid=$vfpPortGuid"
            } else {
                Add-Result 'VFP port match' 'WARN' "endpoint Id substring '$shortId' not found in /list-vmswitch-port output"
            }
        }
    } catch {
        Add-Result 'vfpctrl /list-vmswitch-port' 'FAIL' $_.Exception.Message
    }

    if ($vfpPortGuid) {
        try {
            $portState = & $vfpPath /port $vfpPortGuid /get-port-state 2>&1 | Out-String
            Save-Dump "vfpctrl /port $vfpPortGuid /get-port-state" $portState
        } catch {
            Add-Result 'vfpctrl get-port-state' 'FAIL' $_.Exception.Message
        }
        try {
            # /list-layer with /port enumerates the VFP policy layers attached to the
            # port. This is the schema we'd be writing into for spike 5 (vfpctrl path).
            $layers = & $vfpPath /port $vfpPortGuid /list-layer 2>&1 | Out-String
            Save-Dump "vfpctrl /port $vfpPortGuid /list-layer" $layers
        } catch {
            Add-Result 'vfpctrl list-layer' 'FAIL' $_.Exception.Message
        }
    }
}

Section 'Cleanup'

if ($ownProbe -and -not $KeepProbe) {
    & docker kill $ContainerId 2>$null | Out-Null
    Add-Result 'probe container kill' 'PASS' ''
} elseif ($ownProbe) {
    Add-Result 'probe container retained' 'INFO' "$ContainerId left running for inspection (-KeepProbe)"
}

Section 'Verdict'

$pass = ($script:results | Where-Object Status -eq 'PASS').Count
$fail = ($script:results | Where-Object Status -eq 'FAIL').Count
Write-Host ("  PASS: {0}" -f $pass) -ForegroundColor Green
Write-Host ("  FAIL: {0}" -f $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'DarkGray' })

$hnsOk = $hnsLoaded -and $matchedEndpoint
$vfpOk = [bool]$vfpPath -and $vfpPortGuid

$verdict = if ($hnsOk -and $vfpOk) {
    'GO -- HNS endpoint and VFP port both identified. Proceed to mutate spikes (hns-acl-block, vfp-rule-block).'
} elseif ($hnsOk -or $vfpOk) {
    'INVESTIGATE -- only one of HNS/VFP is addressable from this script. The mutate spike for the working path is still worth running; the other may need a different tool or a newer Windows build.'
} else {
    'NO-GO -- neither HNS nor VFP could be reached from a host-side script. Pivot to documenting the proxy / dedicated-VM fallback in docs/security.md.'
}

Write-Host ''
Write-Host "  Verdict: $verdict" -ForegroundColor Yellow
Write-Host ''

Write-Host 'Notes for follow-up:' -ForegroundColor DarkGray
Write-Host "  - HNS module loaded:       $hnsLoaded"
Write-Host "  - vfpctrl.exe path:        $vfpPath"
Write-Host "  - Matched HNS endpoint Id: $(if ($matchedEndpoint) { $matchedEndpoint.Id } else { '(none)' })"
Write-Host "  - Matched VFP port GUID:   $(if ($vfpPortGuid) { $vfpPortGuid } else { '(none)' })"
Write-Host "  - Captured dump keys:      $(@($script:dump.Keys) -join ', ')"
Write-Host ''
Write-Host '  Next: review the captured policy / rule dumps above, then run the mutate spikes' -ForegroundColor DarkGray
Write-Host '  (hns-acl-block.ps1, vfp-rule-block.ps1 -- not yet written; tracked in issue #3).' -ForegroundColor DarkGray
Write-Host ''

if ($fail -gt 0) { exit 1 } else { exit 0 }
