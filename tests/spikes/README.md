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

## Why these are kept

Both spikes returned negative results, which is exactly why they're worth keeping. The `Future work: host-side enforcement` section of [`docs/security.md`](../../docs/security.md) cites these scripts as evidence — anyone proposing "just add a host firewall rule" can run the spike and see for themselves that Docker Desktop's HCS-based networking doesn't surface to either Hyper-V Firewall, Hyper-V VM ACLs, or plain Defender Firewall. The HNS/VFP path remains untested and is the documented v2 candidate.
