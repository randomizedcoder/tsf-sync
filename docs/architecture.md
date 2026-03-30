# Architecture & Design Rationale

## Core Insight

Intel's `iwlwifi` driver already exposes its WiFi TSF as a PTP hardware clock (`/dev/ptpN`). This means `ptp4l` can already synchronize Intel WiFi cards using standard IEEE 1588 — no custom code needed.

**Our job is to extend this pattern to every other WiFi driver.**

For cards that have `get_tsf`/`set_tsf` through mac80211 (MediaTek, Qualcomm, Realtek, Broadcom, TI — about 20 drivers), we write a kernel module that wraps those ops as a `ptp_clock_info`, registering a `/dev/ptpN` for each card.

Once every WiFi card is a PTP clock, the entire problem reduces to standard PTP clock synchronization — a solved problem with decades of engineering behind it.

---

## What We Build vs What Upstream Provides

### We build

| Component | What it is | Size |
|-----------|-----------|------|
| **`tsf-ptp`** | Kernel module: registers PTP clock per WiFi phy | ~500 lines C |
| **`tsf-sync`** | Userspace: discovery, config generation, lifecycle, monitoring | ~2000 lines Rust |

### Upstream provides (we don't maintain)

| Component | What it does |
|-----------|-------------|
| **`ptp4l`** (linuxptp) | IEEE 1588 PTP daemon. Synchronizes PTP clocks — within a host and across hosts over Ethernet. Best-master-clock election, delay measurement, frequency correction. |
| **`phc2sys`** (linuxptp) | Synchronizes system clock (`CLOCK_REALTIME`) to a PTP hardware clock. |
| **`ts2phc`** (linuxptp) | Synchronizes PTP clocks to external time sources (GPS, 1PPS). |
| **Linux PTP subsystem** | Kernel infrastructure for PTP hardware clocks: `/dev/ptpN`, `clock_gettime`/`clock_adjtime` ioctls, `PTP_SYS_OFFSET_PRECISE` for cross-clock correlation. |

---

## Why PTP Wins

We evaluated several alternative architectures. The comparison:

| Approach | Intra-host sync | Multi-host sync | Maintenance burden | Accuracy |
|----------|----------------|----------------|-------------------|----------|
| **PTP (this design)** | `ptp4l` + kernel module | Same `ptp4l`, add Ethernet | Kernel module + thin userspace tool | Sub-µs (Intel), ~10µs (debugfs) |
| Custom daemon + SeqLock | Custom SeqLock + futex | Custom IPv6 multicast protocol | Full sync protocol + distribution + monitoring | ~1ms (simple set), ~10µs (skew tracking) |
| Custom daemon + channels | Thread-per-card, crossbeam channels | Custom protocol needed | Full sync protocol + per-card threads | ~1ms |
| Async daemon (tokio) | spawn_blocking (all ops block) | Custom protocol needed | Async complexity for zero benefit | ~1ms |

**The PTP approach wins decisively:**

1. **We write less code.** ~500 lines of kernel C + ~2000 lines of Rust orchestration vs ~5000+ lines of custom sync daemon.
2. **We maintain less code.** We don't implement: clock discipline algorithms, frequency estimation, delay measurement, best-master-clock election, multi-host messaging, or any synchronization protocol.
3. **We get multi-host for free.** PTP over Ethernet is a configuration change, not a code change.
4. **We get GPS/atomic clock input for free.** `ts2phc` already exists.
5. **Accuracy improves over time without our involvement.** As `linuxptp` evolves, we benefit.
6. **Datacenter-proven.** PTP synchronizes millions of NICs in production. We're just adding WiFi cards to an existing domain.

### What we give up

- **Kernel module maintenance.** Must rebuild per kernel version (mitigated by DKMS/NixOS).
- **No `adjfine`/`adjfreq`.** WiFi cards can't do hardware frequency correction. PTP falls back to time-stepping, which is slightly less smooth. Acceptable for our use case.
- **`ptp4l` is an external dependency.** But it's packaged everywhere and trivial to deploy.

For the full list of alternatives considered, see [Options Considered](options-considered.md).

---

## Phased Roadmap

### Phase 1 — Single Host (current)

- Build and test `tsf-ptp` kernel module using `mac80211_hwsim`
- Build `tsf-sync` userspace tool (discovery, config generation, lifecycle)
- Validate with real hardware (Intel AX210 + MediaTek MT7925)
- NixOS packaging (flake, service module, kernel module build)

### Phase 2 — Multi-Host

- PTP over Ethernet between hosts using existing `ptp4l` configuration
- `tsf-sync` generates multi-host-aware configs
- Validate cross-host TSF convergence
- Document network requirements (switch configuration, MLD snooping)

### Phase 3 — Upstream

- Submit per-driver PTP patches to upstream kernel (start with mt76, ath9k)
- Engage with driver maintainers
- `tsf-ptp` module becomes unnecessary as drivers gain native PTP support
- `tsf-sync` remains useful for orchestration and monitoring

---

## Open Questions & Risks

1. **mac80211 internal API stability.** The `drv_get_tsf()`/`drv_set_tsf()` helpers and `ieee80211_ops` struct are kernel-internal. Changes between kernel versions require module updates. Mitigation: target LTS kernels, use DKMS, eventually upstream per-driver PTP patches.

2. **VIF requirement.** Most drivers need an active VIF for TSF ops. If no interface is up, the PTP clock can't read TSF. Mitigation: return `-ENODEV` and document the requirement.

3. **No frequency discipline.** WiFi cards can't adjust oscillator frequency. PTP must use time-stepping only, which causes small discontinuities. For our use case (µs-scale accuracy, not ns), this is acceptable. Intel is the exception — `iwlwifi`'s native PTP clock does support `adjfine`.

4. **GP2↔TSF mapping (Intel).** The iwlwifi PTP clock exposes GP2-derived time, not raw TSF. The firmware maintains an internal GP2↔TSF mapping. We need to validate that PTP adjustments actually affect the on-air TSF by capturing beacons and comparing.

5. **Firmware state interference.** Active scanning, association, or channel switching may temporarily block TSF access or return stale values. Need to detect and handle gracefully.

6. **PCIe bus contention.** `ptp4l` may poll many PTP clocks rapidly. 100 concurrent firmware commands could saturate the PCIe bus or hit firmware command queue limits. Mitigation: configure per-clock poll intervals in `ptp4l`.

7. **debugfs path stability.** The kernel module doesn't use debugfs (it calls mac80211 ops directly), so this is a non-issue for `tsf-ptp`. Only matters for fallback userspace access.

8. **Licensing.** The kernel module must be GPL (it uses mac80211 internal APIs). The Rust userspace tool can be MIT. This is fine.

9. **Upstream acceptance.** Long-term, we want per-driver PTP patches upstream (like iwlwifi). The module is a stepping stone. Need to engage with driver maintainers (mt76: Felix Fietkau, ath: Toke Høiland-Jørgensen).

10. **ptp4l with many clocks.** `ptp4l` is typically used with 1-4 clocks. Need to test behavior with 100 clocks on one host. May need multiple `ptp4l` instances or the `ts2phc` approach.

11. **GP2 32-bit wrap.** The GP2 counter wraps every ~71.6 minutes. The iwlwifi driver extends this to 64 bits, but there may be edge cases during the wrap window.

12. **Hot-plug races.** A card may disappear between discovery and first use, or between read and write. All paths must handle `ENOENT`/`ENODEV`.

13. **Multi-host PTP bootstrapping.** PTP convergence takes seconds. During this window, cross-host TSF sync accuracy is degraded. Need a "PTP not yet converged" state.

14. **IPv6 multicast reliability.** For multi-host, UDP multicast can lose packets. Acceptable since TSF data is continuously refreshed, but need sequence numbers to detect staleness.
