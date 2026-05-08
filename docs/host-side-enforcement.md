# Host-side enforcement: investigation outcome

This doc captures the result of [issue #3](https://github.com/vinylflamingo/claude-win-container/issues/3)'s investigation into whether `cwc harden` could be implemented as real, host-enforced isolation rather than the in-container speed-bump it ships as today. The short answer: **no, not from a PowerShell-driven script on the configurations we tested**. The investigation closes here. v1's in-container harden remains the strongest layer cwc ships; users who need real isolation use one of the alternatives documented at the end of this file.

Read this first if you're considering host-side enforcement work, want to understand why we punted on it, or are revisiting the question on a future Windows / Docker Desktop version (the path may re-open — see "How to revisit" below).

## TL;DR

The threat model in [`security.md`](./security.md) names "agent with admin in the container disables harden" as a known limitation. Closing that gap requires enforcement on the host, outside the container's reach. We investigated three host-reachable mutation paths over a series of empirical spikes; none of them produced a working block.

| Path | API surface | Result |
| --- | --- | --- |
| HNS endpoint policy POST | `Invoke-HNSRequest` (or P/Invoke into `vmcompute.dll!HNSCall`) | Metadata-only — ACL appears on the endpoint object, VFP does not reload, traffic unaffected |
| HCN modify endpoint | P/Invoke into `computenetwork.dll!HcnModifyEndpoint` | Same metadata-only result. Modern API, same outcome on Docker-created endpoints |
| vfpctrl direct | `vfpctrl.exe` per-port commands | All 8 invocation patterns tried (`/switch /port`, `/port /vm`, with both port-id and NIC-name forms) rejected with HCS object-not-found |

The earlier prior-art layers (Hyper-V Firewall, Hyper-V VM ACLs, Defender Firewall on the NAT bridge) had already been ruled out in [`hyperv-firewall.ps1`](../tests/spikes/hyperv-firewall.ps1) and [`host-firewall.ps1`](../tests/spikes/host-firewall.ps1) and remain ruled out.

## Tested environment

The findings below were captured on the configuration listed here. **They are not portable to other Windows / Docker Desktop versions without re-running the spikes** — see "Brittleness" below.

| Component | Version |
| --- | --- |
| OS | Windows 11 Pro N, build 26200 |
| Docker Engine / Desktop | 28.2.2 |
| HNS PowerShell module | `HostNetworkingService` 1.0.0.1 (Microsoft-shipped CIM proxy; not microsoft/SDN's `hns.psm1`) |
| `vfpctrl.exe` | `C:\Windows\System32\vfpctrl.exe`, newer CLI variant (`/list-vmswitch-port` action present) |

The choice of single Windows / DD version is per the investigation plan agreed up-front: get a definitive answer on one configuration before considering whether multi-version testing is worth the churn. The result is uniformly negative across the paths we tested, so multi-version sweeping was not pursued.

## What we found

### Path 1: HNS endpoint policy POST

[Spike: [`hns-acl-block.ps1`](../tests/spikes/hns-acl-block.ps1)]

We can attach an ACL policy to a Docker-created HNS endpoint via `Invoke-HNSRequest -Method POST -Type endpoints -Id <id> -Data '{"Policies":[{...}]}'`. The endpoint object's `.Policies` field reflects the new ACL on the next `Get-HnsEndpoint`. **But VFP does not reload its rules.** Traffic from inside the container to a destination inside the policy's `RemoteAddresses` range continues unaffected.

We tried four request shapes against the same endpoint:

| Shape | API result | Effect |
| --- | --- | --- |
| `POST /endpoints/{id}/ApplyPolicy` + flat HNS schema | "The specified request is unsupported" | None |
| `POST /endpoints/{id}` (no action) + flat HNS schema | Success, ACL visible on endpoint | None — metadata-only |
| `POST /endpoints/{id}/Update` + flat HNS schema | "The specified request is unsupported" | None |
| `POST /endpoints/{id}` (no action) + HCN-modify wrapper body | "Unspecified error" | None |

The middle variant (no-action POST) is the only one that the `HostNetworkingService` module accepts cleanly. It mutates the endpoint object's persisted state but does not signal the VFP layer to reapply.

The cleanup-side paths (`/RemovePolicy`, clearing `.Policies`) are similarly broken on this build. A metadata-only ACL becomes an orphan that survives until the container is removed (`docker rm` destroys the endpoint). For an investigative spike this is acceptable; it is not acceptable for a production v2 layer.

### Path 2: HCN `HcnModifyEndpoint` via P/Invoke

[Same spike, fifth variant.]

The modern Microsoft-supported API — `HcnOpenEndpoint` + `HcnModifyEndpoint(ResourceType=Policy, RequestType=Add, Settings={Policies:[...]})` + `HcnCloseEndpoint`, P/Invoke'd into `computenetwork.dll` — produces the same outcome. `HcnModifyEndpoint` returns `HRESULT 0` (success), the ACL appears on the endpoint object, **but VFP does not enforce it**. Same metadata-only state.

This is the most consequential negative finding. HCN is the API that production Kubernetes-on-Windows / CNI plugins use today. If `HcnModifyEndpoint` doesn't reconcile to VFP for Docker-created endpoints on Win 11 / DD 28.2.2, then there is no policy-store mutation path from a script that produces enforcement on this configuration. Our hypothesis: Docker creates endpoints via the legacy HNS API path, the resulting endpoints have an internal "owner" or "compartment" attribute that prevents subsequent HCN modifications from triggering reconciliation. This is consistent with HCN's documented behavior of treating endpoints created outside its surface as opaque.

### Path 3: `vfpctrl` direct

[Spike: [`vfp-rule-block.ps1`](../tests/spikes/vfp-rule-block.ps1)]

VFP is the layer where the actual filtering happens; on every other layer above it (HNS, HCN), policies are advisory until VFP reconciles them. Editing VFP rules directly via `vfpctrl.exe /add-rule-ex` should bypass HNS reconciliation entirely.

`vfpctrl /list-vmswitch-port` (the top-level enumeration) works fine and shows the matched container's port. **Per-port commands do not.** We exhaustively probed 8 invocation patterns against `/get-port-state` (a read-only sanity check) using each combination of:

- `/switch <switch-id>` present or absent
- `/port <port-id>` (the bare GUID from `$endpoint.AdditionalParams.SwitchPortId`)
- `/port <vm-id>--<port-id>` (the full NIC name from `$endpoint.AdditionalParams.VmSwitchNicName`, the form vfpctrl uses for hyperv-isolated container NICs in some configurations)
- `/vm <vm-id>` modifier present or absent

Every pattern returned `ERROR: failed to execute get-port-state / Error (2): The system cannot find the file specified` — HCS's object-not-found error code. The port exists (`Get-HnsEndpoint` confirms it; baseline ICMP from inside the container reaches the gateway, so VFP _is_ enforcing Docker's own rules). vfpctrl just cannot address it.

Without `/get-port-state`, we cannot construct `/add-layer`, `/add-group`, or `/add-rule-ex` calls that vfpctrl will accept either. The spike exits NO-GO before attempting rule modification because the enforcement-layer tool does not surface the port to a host-side script in this configuration.

### Why this isn't an "investigate further" verdict

Three independent mutation paths reach the same wall: the policy store is mutable, the enforcement layer is not addressable from a script. We tried each path in multiple shapes (HNS POST in four request bodies, HCN with the documented schema, vfpctrl in eight invocation patterns). The pattern of failure (metadata accepted, enforcement not reconciled; vfpctrl per-port not found) is consistent with Docker Desktop's HCS-based container creation routing through code paths that don't surface their VFP ports to the in-box management tools the way Hyper-V VMs do.

There may be undocumented APIs we missed. There may be DD-internal vpnkit shims that interpose between PowerShell and the actual port. There may be a Microsoft-internal tool that does work. None of those are reachable from a script we can ship to users. The investigation's question was _can we do this from a host-side script today_, and on this build the answer is no.

## What we are NOT doing

The issue's acceptance criteria require a clear outcome. Here is what is explicitly out:

- **No v2 implementation issue.** There is no candidate path to implement. The `[ ] follow-up implementation issue exists` checkbox is consciously unchecked; the alternative — _"this issue's outcome is 'we're sticking with the in-container speed-bump indefinitely'"_ — is what we're choosing.
- **No regression to the existing layers.** [`security.md`](./security.md) is updated to point at this doc but otherwise unchanged. The five existing defense layers continue to ship unmodified.
- **No multi-version sweep.** Testing every Win/DD combination is not warranted given the negative result on a current stable. If a future re-test produces a positive result, that's when the investment is justified.

## Brittleness and what would change the result

This is a frozen-in-time empirical finding. Three things could plausibly unblock the path:

1. **A future Windows release surfaces vfpctrl per-port commands for HCS containers.** vfpctrl is a Microsoft-internal tool that has shipped in different shapes across builds; per-port addressability could come (or go) in a Windows update. The `hns-vfp-discovery.ps1` spike is the canary — re-run it; if `/get-port-state` works under any pattern, retest the rest.
2. **A future Docker Desktop release uses HCN to create endpoints.** If Docker switches from legacy HNS endpoint creation to HCN, after-the-fact `HcnModifyEndpoint` calls might propagate to VFP. Re-run `hns-acl-block.ps1`; if the HCN P/Invoke variant now produces a traffic effect, the path opens.
3. **A new Microsoft-supported policy API ships.** Microsoft has introduced `HostComputeNetwork` (HCN) on top of HNS; a future iteration could expose primitives that today's APIs lack. Watch the [HCN schemas docs](https://learn.microsoft.com/en-us/virtualization/api/hcn/Schemas).

If any of those happen, this doc should be revisited. Otherwise, the next investigation should _not_ start from scratch — the spikes capture the schema and tooling so a re-run takes minutes.

## Recommended alternatives

For users who need stronger isolation than `cwc harden`'s in-container watchdog provides, two paths give real isolation today. Neither is integrated with cwc; both impose setup cost on the user.

### Alternative A: Host-side filtering proxy

The strongest practical option. A proxy on the host intercepts all egress from the container, applies an FQDN allowlist, and forwards approved traffic. The container has no other network path because LAN lockdown (defense layer 2) and the entrypoint's hosts-file management force everything through the proxy.

Recommended tool: [mitmproxy](https://mitmproxy.org/). It runs natively on Windows, supports a filter-script mode that can implement an FQDN allowlist in ~20 lines of Python, and ships its own CA cert generation.

Concrete setup outline:

1. Install mitmproxy on the host: `winget install mitmproxy.mitmproxy`. The CA cert lands at `%USERPROFILE%\.mitmproxy\mitmproxy-ca-cert.pem` after the first run.
2. Write a filter script that allows only the FQDNs you want (e.g. `api.anthropic.com`, your project's git host) and blocks everything else. Save as `cwc-allowlist.py` somewhere durable.
3. Run mitmproxy as a service or scheduled task: `mitmdump --listen-host 127.0.0.1 --listen-port 8080 -s cwc-allowlist.py`. (Use mitmweb interactively while you tune the script, then switch to mitmdump for production.)
4. Configure cwc to point the container at the proxy. Add to `~/.cwc/projects/<slug>/config.json`:
   - Set env vars `HTTP_PROXY=http://host.docker.internal:8080` and `HTTPS_PROXY=http://host.docker.internal:8080` via the project overlay (`claude-sandbox.overlay.yml`).
   - Bind-mount the CA cert into the container's trust store. The Server Core image's cert location is `C:\ProgramData\PKI\Trust\Root\`. A startup hook in your overlay can `Import-Certificate` it.
   - Use `cwc firewall host-add host.docker.internal host-gateway 8080` so the proxy is reachable through the locked-down network.
   - Ensure the LAN lockdown is on (`cwc firewall enable`) so non-proxy egress paths are blackholed.

The proxy is now a host-controlled choke point. An agent in the container can issue any HTTPS request it wants, but only requests to allowlisted FQDNs reach the internet — and the host-process-level proxy is outside the container's reach.

Trade-offs:
- One additional moving part (the proxy process). If it crashes, agents have no egress.
- TLS interception: the agent sees mitmproxy's CA cert, not the real one. Some sites pin certs; those break.
- Per-FQDN allowlists are coarser than per-API-endpoint. A compromised allowed FQDN (e.g., a CDN serving multiple unrelated sites) becomes a leak surface.

This is the recommended option for almost everyone who needs stronger-than-speed-bump isolation.

### Alternative B: Dedicated Windows VM running Docker Desktop

Real hypervisor-level isolation. Run cwc inside a Windows VM whose virtual NIC is on a private vSwitch with no internet path, or on an isolated NAT'd vSwitch you control.

Concrete setup outline:

1. Enable Hyper-V on the host (`Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All`).
2. Create a Windows 11 VM (16+ GB RAM, 80+ GB disk for Docker images) with `New-VM`. Use a dynamic memory and 4+ vCPUs.
3. Install Windows in the VM.
4. Inside the VM, install Docker Desktop, Git for Windows, and PowerShell 7.
5. Inside the VM, install cwc per the [README](../README.md) instructions.
6. Configure the VM's network. Either:
   - Private vSwitch + Hyper-V Firewall outbound rules — the only egress path is whatever you explicitly allow (e.g., `api.anthropic.com`).
   - Internal vSwitch with no external uplink — the VM has no internet at all; you'd add a tightly scoped proxy on the host as the only path out.
7. Use cwc inside the VM. Containers run in a VM that runs in a VM (Docker Desktop's MobyLinux backend or Windows containers' UVM nested in your dedicated VM).

Trade-offs:
- Real isolation: the VM boundary is hypervisor-enforced. An agent breaking out of the container faces a Hyper-V VM next; getting from there to the host requires a VM escape (rare, well-funded).
- Setup cost: half a day to get a clean working environment, plus ongoing OS-update maintenance for the VM.
- Resource cost: the VM permanently consumes RAM and CPU even when idle.

Pursue this if cwc is mediating access to genuinely sensitive data and the proxy alternative isn't strict enough.

### What about Linux containers / WSL2 backend?

cwc is Windows-containers-only. Docker Desktop's Linux-containers / WSL2 path is a different architecture and has different host-side options (Linux iptables / nftables). Out of scope for this investigation.

## How to revisit

The spikes are preserved. To re-test on a future Windows or Docker Desktop version:

1. Run [`hns-vfp-discovery.ps1`](../tests/spikes/hns-vfp-discovery.ps1). If `/get-port-state` succeeds under any pattern in spike 5's probe, the vfpctrl path is back on the table.
2. Run [`hns-acl-block.ps1`](../tests/spikes/hns-acl-block.ps1). If the HCN P/Invoke variant produces a traffic effect (the loop now treats traffic-blocking as the authoritative success signal), the HCN path is back on the table.
3. If either returns GO, re-open issue #3 with the new finding and the version it was observed on.

The spikes self-clean and run as Administrator. Nothing in cwc itself depends on the negative result, so re-tests are non-destructive.

## Summary table

| Question | Answer |
| --- | --- |
| Path chosen | None — NO-GO for HNS / HCN / vfpctrl on the tested configuration |
| Lifecycle integration plan | Not applicable; no path produced enforcement |
| DD versions tested | 28.2.2 only (single-version per the agreed plan) |
| Brittleness assessment | High — Microsoft / Docker internals could change; the result is true for one snapshot in time |
| Implementation effort estimate | Not applicable for HNS/VFP. Proxy alternative: a few hours one-time setup. VM alternative: half a day setup, ongoing maintenance |
| Follow-up implementation issue | None. cwc continues with the in-container `harden` speed-bump as the strongest layer it ships |
