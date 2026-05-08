# Spikes

One-off investigative scripts. Not part of the regular test suite (`tests/run.ps1`).

A spike answers a specific design question with empirical data — does API X exist on this host, does technique Y actually work — before we commit a chunk of implementation effort to a path that might be a dead end.

## Spikes

### `hyperv-firewall.ps1`

Tests whether Hyper-V Firewall (Win 11 22H2+ / Server 2025) and/or legacy vNIC extended ACLs can effectively block Docker Desktop container egress. **Result on Win 11 24H2 + Docker Desktop 28.x: INVESTIGATE — neither path works.** Docker uses HCS directly and doesn't register with Hyper-V VM Manager or Hyper-V Firewall.

```powershell
.\tests\spikes\hyperv-firewall.ps1
```

### `host-firewall.ps1`

Follow-up to `hyperv-firewall.ps1`. Tests whether plain Windows Defender Firewall outbound rules — scoped by source-IP, NAT-bridge interface, or both — can block container egress without affecting host or unrelated traffic. **Result on Win 11 24H2 + Docker Desktop 28.x: INVESTIGATE — none of the three Defender Firewall scopings affect container traffic.** Docker Desktop's networking goes through HNS / VFP, which intercepts traffic *below* the WFP layer where Defender Firewall rules apply.

```powershell
.\tests\spikes\host-firewall.ps1
```

Reports a verdict: `GO` (build harden using the simplest winning approach) or `INVESTIGATE` (move to HNS/VFP). Cleans up after itself.

### `hns-vfp-discovery.ps1`

First spike of the issue #3 investigation into host-side enforcement via HNS / VFP. **Read-only.** Spawns a probe container, locates the matching HNS endpoint, dumps endpoint policies, locates the corresponding VFP port, dumps VFP rules and layers. Captures the schema we'd be writing into for the follow-up mutate spikes. Reports `GO` (both HNS API and vfpctrl reachable; endpoint and port identified), `INVESTIGATE` (one path reachable, not both), or `NO-GO` (neither reachable; pivot to proxy/VM fallback). **Result on Win 11 26200 + Docker Desktop 28.2.2: GO** — endpoint matched (with empty `.Policies` on plain nat-attached containers, so no Docker collisions), VFP port name == endpoint Id (also exposed as `$endpoint.AdditionalParams.SwitchPortId`).

```powershell
.\tests\spikes\hns-vfp-discovery.ps1
.\tests\spikes\hns-vfp-discovery.ps1 -KeepProbe          # leave probe container running for inspection
.\tests\spikes\hns-vfp-discovery.ps1 -ContainerId <id>   # use an existing container instead
```

Requires the HNS PowerShell module (`Get-HnsEndpoint`). It is not bundled with Docker Desktop or Windows client SKUs by default — fetch `hns.psm1` from [microsoft/SDN](https://github.com/microsoft/SDN/tree/master/Kubernetes/windows) into `C:\Program Files\WindowsPowerShell\Modules\HNS\` if the spike reports `WARN` on that line.

vfpctrl gotcha encoded in the script: modifiers (`/port`, `/switch`, `/layer`, `/group`) must precede the action verb (`/list-layer`, `/list-rule`, etc.); `/list-port` is not a valid action — use `/list-vmswitch-port` for top-level enumeration or `/port <name> /get-port-state` for per-port queries.

### `hns-acl-block.ps1`

Second mutating spike of the issue #3 investigation. Adds an HNS endpoint ACL blocking RFC1918 destinations from a probe container, then verifies block + allow-target reachability + host non-regression + removal restores access. Also probes whether the policy survives `docker stop` + `docker start`. The spike tries up to **five** request shapes in order — `ApplyPolicy` flat schema, no-action POST flat, `Update` action, no-action POST with HCN-modify wrapper, and finally `HcnModifyEndpoint` via P/Invoke into `computenetwork.dll` — and stops on the first that both succeeds at the API level **and** produces an actual traffic block. Self-contained: if the loaded HNS module doesn't export `Invoke-HNSRequest` the spike defines a minimal one inline via P/Invoke into `vmcompute.dll!HNSCall`. Cleans up the policy and the probe container on exit (try/finally).

```powershell
.\tests\spikes\hns-acl-block.ps1
.\tests\spikes\hns-acl-block.ps1 -KeepProbe              # leave probe container running
.\tests\spikes\hns-acl-block.ps1 -KeepPolicy             # leave the ACL applied (DANGER: probe container will be partly broken)
.\tests\spikes\hns-acl-block.ps1 -ContainerId <id>       # use an existing container
```

**Result on Win 11 26200 + Docker Desktop 28.2.2 + HostNetworkingService module 1.0.0.1: NO-GO.** The no-action POST variant and the HCN `HcnModifyEndpoint(Add)` variant both attach the ACL to the endpoint object's `.Policies` array, but neither triggers VFP reconciliation — container traffic continues unaffected. Both are policy-aware but not enforcement-triggering on this build. See [`docs/host-side-enforcement.md`](../../docs/host-side-enforcement.md) for the full writeup.

### `vfp-rule-block.ps1`

Third mutating spike. Skips HNS entirely and writes a rule directly to the VFP port via `vfpctrl.exe`. Adds a unique-id custom layer at priority 1 (highest, default-allow), one outbound group inside it, one block rule for the configured RFC1918 range. `/remove-layer` cleans up everything transitively. Same verdict convention. Probes whether the rule survives `docker stop` + `docker start` (expected: no — VFP ports rotate on container restart).

Includes an invocation-pattern probe: vfpctrl's per-port commands have shipped with different modifier orderings across Windows builds, so the spike tries 8 patterns (`/switch /port`, `/port /switch`, `/port` alone, `/vm /port`, with both bare port-id and full `<vm-id>--<port-id>` NIC-name forms) against `/get-port-state` before constructing any modifying calls.

```powershell
.\tests\spikes\vfp-rule-block.ps1
.\tests\spikes\vfp-rule-block.ps1 -KeepRule              # leave the layer applied
.\tests\spikes\vfp-rule-block.ps1 -KeepProbe             # leave probe container running
.\tests\spikes\vfp-rule-block.ps1 -ContainerId <id>      # use an existing container
.\tests\spikes\vfp-rule-block.ps1 -BlockedRange 10.0.0.0/8  # override the RFC1918 range
```

**Result on Win 11 26200 + Docker Desktop 28.2.2: NO-GO.** All 8 invocation patterns rejected with HCS object-not-found. `vfpctrl /list-vmswitch-port` (top-level) works fine and shows the matched container's port; per-port commands are not addressable from the host script on this build.

The combined verdict for the issue #3 investigation is NO-GO: HNS POST is metadata-only, HCN P/Invoke is metadata-only, vfpctrl per-port commands are unaddressable. v1 stays with the in-container `cwc harden` speed-bump; users who need stronger isolation use the proxy / VM alternatives written up in [`docs/host-side-enforcement.md`](../../docs/host-side-enforcement.md).

## Why these are kept

The first two spikes returned negative results, which is exactly why they're worth keeping. The `Future work: host-side enforcement` section of [`docs/security.md`](../../docs/security.md) cites these scripts as evidence — anyone proposing "just add a host firewall rule" can run the spike and see for themselves that Docker Desktop's HCS-based networking doesn't surface to either Hyper-V Firewall, Hyper-V VM ACLs, or plain Defender Firewall. The HNS/VFP investigation (`hns-vfp-discovery.ps1` and follow-ups) is the v2 candidate path; tracked under [issue #3](https://github.com/vinylflamingo/claude-win-container/issues/3).
