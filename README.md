# tsf-sync

Synchronize WiFi TSF (Timing Synchronization Function) phase across co-located Access Points on a single concentrator host. One radio is the timing master; the rest are secondaries. The host reads the master's TSF, computes the offset to each secondary, and corrects them via the driver's `set_tsf` — a classic master/slave clock discipline loop.

While reviewing the kernel source, we discovered that Intel ships PTP hardware clock support as a [first-class feature of their WiFi NICs](https://github.com/torvalds/linux/blob/master/drivers/net/wireless/intel/iwlwifi/mvm/ptp.c) — the `iwlwifi` driver registers each card's TSF as a `/dev/ptpN` clock with cross-timestamping, frequency adjustment, and GP2 hardware counter integration. Rather than building a custom synchronization daemon, we extended this pattern to every other SoftMAC WiFi driver and reuse the Linux PTP ecosystem (`phc2sys`) to drive the read → compare → correct loop. PTP is the transport mechanism, not the goal — see [This Is Not Traditional PTP](#this-is-not-traditional-ptp).

**Current hardware:** 24 WiFi cards (Intel AX210 + MediaTek MT7925), scaling to 60-100+ per host, multiple hosts.

---

## Quick Start (NixOS)

```bash
# Build everything
nix build                         # Rust binary
nix build .#kernel-module         # Kernel module for your running kernel

# Enter development shell (Rust + linuxptp + kernel headers)
nix develop

# Run automated smoke test (loads hwsim, tests threshold, cleans up)
sudo nix run .#test-hwsim

# Run sync and monitor counters for 30 seconds
sudo nix run .#test-sync

# CI checks (fmt + clippy + test + build)
nix flake check
```

See [Nix Reference](docs/nix.md) for all flake outputs, NixOS module configuration, and test scripts.

---

## This Is Not Traditional PTP

**Traditional PTP** synchronizes wall-clock time (UTC/TAI) across network devices — NICs, switches, grandmasters with GPS receivers. The goal is nanosecond-accurate wall-clock agreement.

**What we do** is fundamentally different: we synchronize BSS phase (the WiFi TSF counter) between co-located radios on the same host. There is no wall clock involved.

We repurpose the PTP kernel API (`ptp_clock_info`) as a **transport mechanism** to expose each radio's TSF read/write ops to userspace. `phc2sys` runs with `-O 0` (no UTC/TAI offset) — it sees raw TSF values and drives TSF-to-TSF convergence.

The sync loop is functionally: `read master TSF → read slave TSF → compute offset → set_tsf on slave`. PTP infrastructure handles the bookkeeping; our kernel module does the actual TSF access.

We chose this approach because the PTP clock API is a stable, well-maintained kernel interface for "expose a hardware clock and let userspace discipline it." That's exactly our use case — WiFi TSF is a hardware clock.

---

## Data Flow: How TSF Moves Through the System

### Sync cycle (one iteration, one secondary)

Shows how a TSF value is read from the primary NIC, travels through kernel and userspace, and results in a correction written to the secondary NIC. All NICs are PCIe-attached.

```
                    Userspace                          Kernel                        PCIe Bus            Hardware
                    ─────────                          ──────                        ────────            ────────

 ┌─ Step 1: Sample primary TSF ──────────────────────────────────────────────────────────────────────────────────┐
 │                                                                                                               │
 │  phc2sys                                                                                                      │
 │  clock_gettime(/dev/ptp0) ──► PTP subsystem ──► tsf_ptp_gettime() ──► ops->get_tsf() ══► MMIO read ──► NIC 0 │
 │                           ◄── tsf_usec ◄─────── tsf_usec ◄────────── tsf_usec ◄════════ TSF register          │
 │                                                                                                               │
 └───────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

 ┌─ Step 2: Sample secondary TSF ────────────────────────────────────────────────────────────────────────────────┐
 │                                                                                                               │
 │  phc2sys                                                                                                      │
 │  clock_gettime(/dev/ptp1) ──► PTP subsystem ──► tsf_ptp_gettime() ──► ops->get_tsf() ══► MMIO read ──► NIC 1 │
 │                           ◄── tsf_usec ◄─────── tsf_usec ◄────────── tsf_usec ◄════════ TSF register          │
 │                                                                                                               │
 └───────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

 ┌─ Step 3: Compute offset (pure math, no I/O) ─┐
 │                                                │
 │  phc2sys                                       │
 │  offset = primary_tsf - secondary_tsf          │
 │                                                │
 └────────────────────────────────────────────────┘

 ┌─ Step 4: Correct secondary TSF ───────────────────────────────────────────────────────────────────────────────┐
 │                                                                                                               │
 │  phc2sys                                                                                                      │
 │  clock_adjtime(/dev/ptp1,     PTP subsystem     tsf_ptp_adjtime(delta_ns):                                    │
 │    offset_ns)  ─────────────►  ─────────────►     if |delta| < threshold → skip (no PCIe)                     │
 │                                                   else:                                                       │
 │                                                     ops->get_tsf()  ══════════► MMIO read  ──► NIC 1          │
 │                                                     tsf_usec ◄══════════════════ TSF register                  │
 │                                                     new_tsf = tsf + delta                                     │
 │                                                     ops->set_tsf()  ══════════► MMIO write ──► NIC 1          │
 │                                                                                  TSF register updated          │
 └───────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

 Repeats every 100 ms (10 Hz).  With N secondaries, Steps 2-4 repeat for each.
```

### PCIe bus topology and transaction counts

```
 ┌──────────┐
 │   CPU    │
 │          │
 └────┬─────┘
      │  system bus
 ┌────┴──────────────────┐
 │  PCIe Root Complex    │
 └──┬─────┬─────┬────┬──┘
    │     │     │    │   PCIe lanes
  ┌─┴──┐┌─┴──┐┌─┴──┐┌┴───┐
  │NIC0││NIC1││NIC2││ ...│
  │ptp0││ptp1││ptp2││    │
  │MSTR││SLV ││SLV ││    │
  └────┘└────┘└────┘└────┘

 PCIe transactions per 100 ms sync cycle:
 ┌────────────────────────────────────────────────────────────┐
 │ Per-secondary card:                                        │
 │   1× MMIO read  on master NIC  (Step 1: sample primary)   │
 │   1× MMIO read  on this NIC    (Step 2: sample secondary) │
 │   1× MMIO read  on this NIC    (Step 4: adjtime get_tsf)  │
 │   1× MMIO write on this NIC    (Step 4: adjtime set_tsf)  │
 │   ─────────────────────────────────────────────────────    │
 │   = 4 PCIe transactions per secondary per cycle            │
 │                                                            │
 │ If |offset| < threshold (steady state):                    │
 │   Skips Step 4 entirely → only 2 PCIe transactions         │
 │   (1 read master + 1 read secondary)                       │
 │                                                            │
 │ For N secondaries:                                         │
 │   Converging: 1 + 3N transactions (master read shared)     │
 │   Steady state: 1 + N transactions                         │
 │                                                            │
 │ Example: 23 secondary cards                                │
 │   Converging: 1 + 69 = 70 PCIe transactions / 100 ms      │
 │   Steady:     1 + 23 = 24 PCIe transactions / 100 ms      │
 └────────────────────────────────────────────────────────────┘

 Transaction latency by driver type:
 ┌──────────────────────────────────────────────────────────────────┐
 │ Register-based (ath9k, rtw88):                                   │
 │   CPU ──► PCIe TLP ──► NIC MMIO register ──► PCIe TLP ──► CPU   │
 │   Latency: 1-10 µs round-trip                                   │
 │                                                                  │
 │ Firmware-based (ath10k, mt76):                                   │
 │   CPU ──► PCIe TLP ──► NIC cmd queue ──► firmware processes      │
 │       ◄── PCIe TLP ◄── NIC event queue ◄── firmware responds     │
 │   Latency: 10-500 µs round-trip                                  │
 │                                                                  │
 │ Native PTP (iwlwifi):                                            │
 │   CPU ──► PCIe TLP ──► GP2 hardware counter ──► PCIe TLP ──► CPU│
 │   Latency: < 1 µs round-trip                                    │
 └──────────────────────────────────────────────────────────────────┘
```

PTP is just the ioctl plumbing between userspace and kernel — the actual work is MMIO reads/writes to NIC TSF registers over PCIe. The same reads and writes would happen in a pure in-kernel loop. The threshold filter eliminates most PCIe traffic in steady state — once clocks converge, only sampling transactions occur, not corrections.

---

## Timing Loop Placement

The sync loop can run in userspace or entirely in-kernel. Here are the tradeoffs:

**Current: Userspace (`phc2sys` at 10 Hz)** — `phc2sys` polls both clocks, computes the offset, and calls `clock_adjtime` via ioctl. The kernel module translates `adjtime` → `get_tsf` + offset + `set_tsf`.

**Alternative: Entirely in-kernel (kernel timer or workqueue)** — A kernel timer or workqueue could call the same `get_tsf`/`set_tsf` ops directly. No context switch, no userspace scheduling jitter.

| Aspect | Userspace (current) | In-kernel |
|--------|-------------------|-----------|
| **Latency** | ~10-100 µs scheduling jitter from context switch | Sub-µs, no context switch |
| **Sufficient for target?** | Yes — target is ≤10 µs TSF alignment; polling jitter is noise relative to driver-level `get_tsf` latency (1-500 µs) | Would matter for sub-µs targets |
| **Fault isolation** | Bug crashes a userspace process, not the kernel. Systemd restarts it. | Bug can panic/lock the kernel. Recovery requires reboot. |
| **Security** | Runs with limited capabilities (`CAP_SYS_RAWIO`, `CAP_SYS_TIME`). Attack surface is a userspace binary. | Runs in ring 0. A vulnerability is a kernel exploit. |
| **Debuggability** | Standard tools: strace, gdb, journald | Requires printk, ftrace, kgdb |
| **Configurability** | Easy to change poll rate, add monitoring, hot-plug logic | Requires module reload or sysfs knobs |
| **Ecosystem reuse** | `phc2sys` is battle-tested, maintained by linuxptp | Custom sync loop — we own all the code and bugs |

**Conclusion:** Userspace is the right default. The kernel/userspace boundary cost (~100 µs worst case) is negligible compared to firmware-based `get_tsf` latency (10-500 µs on ath10k, mt76). The data flow diagrams above show that the same PCIe transactions happen regardless of where the loop runs — the boundary crossing is a rounding error on the total cycle time.

If a future deployment needs sub-µs precision and uses register-based drivers (ath9k, rtw88), moving the loop in-kernel is a straightforward optimization — the kernel module's `tsf_ptp_adjtime()` is already the in-kernel sync primitive; it just needs a kernel timer to call it instead of `phc2sys`.

---

## How It Works

Our kernel module (`tsf-ptp`) bridges the PTP clock API to mac80211's `get_tsf`/`set_tsf` for every SoftMAC WiFi driver (~20 drivers gain PTP support). Intel NICs have this [built into `iwlwifi`](https://github.com/torvalds/linux/blob/master/drivers/net/wireless/intel/iwlwifi/mvm/ptp.c) natively. Once every WiFi card is a PTP clock, synchronization reduces to reading and writing TSF values through a standard kernel interface.

### Single host

One NIC is the timing master. `phc2sys` reads its TSF at 10 Hz, reads each secondary's TSF, computes the offset, and corrects via `set_tsf`:

```
                         ┌─────────────┐
          read TSF       │   phc2sys   │     read TSF + correct
       ┌────────────────►│   (10 Hz)   │◄──────────────────────┐
       │                 └──────┬──────┘                       │
       │                read + │ correct                       │
       │                       │                               │
  ┌────┴─────┐          ┌──────┴──────┐                 ┌──────┴──────┐
  │  NIC 0   │          │   NIC 1     │                 │   NIC N     │
  │ /dev/ptp0│          │  /dev/ptp1  │       ...       │  /dev/ptpN  │
  │  MASTER  │          │  SECONDARY  │                 │  SECONDARY  │
  │  (AX210) │          │  (MT7925)   │                 │  (any card) │
  └──────────┘          └─────────────┘                 └─────────────┘

  For each secondary every 100 ms:
    1. Read master TSF        (1 PCIe read)
    2. Read secondary TSF     (1 PCIe read)
    3. offset = master - secondary
    4. If |offset| > threshold: set_tsf on secondary (1 read + 1 write)
       Else: skip — already converged, no PCIe write
```

### Multi-host: all NICs across all hosts in sync

For multiple hosts, `ptp4l` runs on each host and communicates over Ethernet using the IEEE 1588 PTP protocol. One clock is elected grandmaster via PTP's Best Master Clock Algorithm — this can be a WiFi NIC, an Ethernet NIC with hardware timestamping, or an external source (GPS, atomic clock). Each host then independently syncs its local WiFi NICs using the same `phc2sys` loop:

```
                        ┌─────────────────┐
                        │ PTP Grandmaster  │
                        │ (Host A NIC 0,   │
                        │  GPS receiver,   │
                        │  or Ethernet PHC)│
                        └────────┬────────┘
                                 │
                     PTP over Ethernet (IEEE 1588)
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
     ┌────────┴────────┐        │         ┌────────┴────────┐
     │     Host A      │        │         │     Host B      │
     │                 │        │         │                 │
     │  ptp4l ◄────────┼────────┼─────────┼───────► ptp4l  │
     │    │            │                  │            │    │
     │  phc2sys        │                  │         phc2sys │
     │    │            │                  │            │    │
     │  ┌─┴──┬────┐   │                  │   ┌────┬──┴─┐  │
     │  │    │    │   │                  │   │    │    │  │
     │ NIC0 NIC1 NIC2 │                  │ NIC0 NIC1 NIC2│
     │  GM  SEC  SEC  │                  │ SEC  SEC  SEC  │
     └────────────────┘                  └────────────────┘
```

The synchronization hierarchy:

1. **`ptp4l`** on each host syncs one local PTP clock to the grandmaster over Ethernet
2. **`phc2sys`** on each host syncs all local WiFi NICs to that host's primary clock
3. **Result:** every WiFi NIC on every host converges to the same TSF

No code changes from single-host to multi-host — just a `ptp4l` configuration change to add the Ethernet interface as a PTP transport. See [PTP Topology & Scaling](docs/ptp-topology.md) for configuration details.

### What we build

| Component | What it is | What it does |
|-----------|-----------|-------------|
| **[`tsf-ptp`](docs/kernel-module.md)** | Out-of-tree Linux kernel module | Registers a PTP clock (`/dev/ptpN`) per WiFi phy that has mac80211 `get_tsf`/`set_tsf`. |
| **[`tsf-sync`](docs/userspace-tool.md)** | Rust CLI / NixOS service | Discovers cards, generates `ptp4l` config, manages lifecycle, monitors health. |

### What upstream provides (we don't maintain)

| Component | What it does |
|-----------|-------------|
| **`ptp4l`** | IEEE 1588 PTP daemon — synchronizes clocks within and across hosts. |
| **`phc2sys`** | Synchronizes system clock to a PTP hardware clock. |
| **`ts2phc`** | Synchronizes PTP clocks to external time sources (GPS, 1PPS). |

### Why reuse the PTP ecosystem?

We write ~500 lines of kernel C + ~2000 lines of Rust. We get single-host sync, multi-host sync, GPS/atomic clock input, system clock integration, sub-µs accuracy, and standard monitoring — all by leveraging existing PTP infrastructure rather than building a custom sync protocol. See [Architecture & Design Rationale](docs/architecture.md) for the full evaluation of alternatives.

---

## Hardware Support

**1 driver** has native PTP (Intel iwlwifi). **~20 drivers** gain PTP through our `tsf-ptp` module. **5 FullMAC drivers** are not supportable (firmware owns TSF).

| Tier | Drivers | PTP path |
|------|---------|----------|
| **Tier 1: Native PTP** | iwlwifi (Intel AX200/210/211, BE200) | Already works with `ptp4l` |
| **Tier 2: tsf-ptp module** | mt76, ath9k, ath10k, ath11k, ath12k, rtw88, rtw89, brcmsmac, b43, carl9170, wlcore, wcn36xx, p54, ath5k, iwlegacy | Our kernel module bridges `get_tsf`/`set_tsf` → PTP |
| **Tier 3: Read-only** | rtl8xxxu, wil6210 | Can read TSF but not write |
| **Unsupported** | brcmfmac, mwifiex, ath6kl, zd1211rw, lbtf | FullMAC or no TSF ops |

Full details: [Driver Compatibility Survey](docs/driver-survey.md)

---

## Project Structure

```
tsf-sync/
├── docs/                              # Design documents
│   ├── architecture.md                # Architecture, rationale, design decisions
│   ├── driver-survey.md               # Full driver compatibility table
│   ├── kernel-module.md               # tsf-ptp module design & challenges
│   ├── userspace-tool.md              # tsf-sync CLI & daemon design
│   ├── ptp-topology.md                # PTP configuration & multi-host scaling
│   ├── testing.md                     # Testing strategy & mac80211_hwsim
│   ├── error-handling.md              # Error classification & health monitoring
│   └── options-considered.md          # Alternatives evaluated & rejected
│
├── kernel/                            # tsf-ptp kernel module
│   ├── tsf_ptp.c                      # PTP clock registration, mac80211 bridge
│   ├── tsf_ptp.h                      # Internal header
│   ├── Makefile                       # Kbuild makefile
│   ├── dkms.conf                      # DKMS for non-NixOS
│   └── tests/
│       ├── test_hwsim.sh              # Full integration test with hwsim
│       └── validate_hwsim_tsf.sh      # Foundation validation (no module needed)
│
├── src/                               # Rust userspace tool
│   ├── main.rs                        # CLI entry (discover, config, start, status, stop)
│   ├── lib.rs                         # Re-exports
│   ├── discovery.rs                   # Sysfs scanning, driver identification
│   ├── config_gen.rs                  # ptp4l.conf generation
│   ├── daemon.rs                      # Daemon mode, lifecycle, hot-plug
│   ├── health.rs                      # Health monitoring via pmc
│   ├── ptp4l.rs                       # ptp4l process management
│   └── module_loader.rs               # Kernel module loading/unloading
│
├── tests/                             # Rust tests
│   ├── discovery_test.rs
│   ├── config_gen_test.rs
│   └── integration/
│       └── hwsim_test.rs              # Full stack with mac80211_hwsim
│
├── nix/                               # NixOS packaging
│   ├── package.nix                    # Crane-based Rust build
│   ├── kernel-module.nix              # Kernel module build
│   ├── devshell.nix                   # Development shell (Rust + kernel headers)
│   ├── ci.nix                         # CI checks (fmt, clippy, test, build)
│   ├── module.nix                     # NixOS service module (systemd)
│   └── scripts.nix                    # Test/build helper scripts
│
├── flake.nix
├── Cargo.toml
└── LICENSE
```

---

## Dependencies

### Rust userspace tool

| Crate | Purpose |
|-------|---------|
| `clap` | CLI argument parsing |
| `tracing` + `tracing-subscriber` | Structured logging |
| `nix` | libc wrappers — sysfs, process management, inotify |
| `thiserror` | Error type derivation |

**Notably absent:** `tokio` — all operations are blocking with seconds-scale intervals.

### Kernel module

- Linux kernel headers, `linux/ptp_clock_kernel.h`, `net/mac80211.h`

### Runtime

- `linuxptp` (`ptp4l`, `phc2sys`, `pmc`, `ts2phc`)

---

## Documentation

| Document | Description | Status |
|----------|-------------|--------|
| **[Project Status](docs/status.md)** | **Current phase, completed work, next steps, risks** | **Living document** |
| [Architecture & Design Rationale](docs/architecture.md) | Core insight, PTP as transport, what we build vs upstream | Complete |
| [Driver Compatibility Survey](docs/driver-survey.md) | TSF/PTP support across all Linux WiFi drivers | Complete |
| [Kernel Module: tsf-ptp](docs/kernel-module.md) | Module design, PTP↔mac80211 mapping, challenges | Complete |
| [Userspace Tool: tsf-sync](docs/userspace-tool.md) | CLI, daemon mode, discovery, config generation | Complete |
| [PTP Topology & Scaling](docs/ptp-topology.md) | Single-host, multi-host, GPS input configurations | Complete |
| [WiFi Timing Requirements](docs/wifi-timing.md) | 802.11 timing, sync accuracy targets, threshold tuning | Complete |
| [Testing Strategy](docs/testing.md) | mac80211_hwsim, integration tests, test matrix | Complete |
| [Error Handling](docs/error-handling.md) | Error classification, health state machine, monitoring | Complete |
| [Options Considered](docs/options-considered.md) | Alternatives evaluated and why they were rejected | Complete |
| [Nix Reference](docs/nix.md) | Flake outputs, dev shell, test scripts, NixOS module, CI | Complete |
| [Deployment Guide](docs/deployment.md) | NixOS module, DKMS, manual setup | Complete |
| [Multi-Host Operations](docs/multi-host.md) | Cross-host PTP setup, network requirements | Placeholder — Phase 2 |
| [Upstream Roadmap](docs/upstream.md) | Per-driver PTP patches, kernel maintainer engagement | Placeholder — Phase 3 |

---

## Open Questions & Risks

1. **mac80211 internal API stability** — kernel module needs updates per version. Mitigated by DKMS/NixOS, long-term by upstreaming per-driver patches.
2. **No frequency discipline** — WiFi cards lack tunable oscillators. PTP falls back to time-stepping. Acceptable for µs-scale accuracy.
3. **Intel PTP ↔ TSF mapping** — iwlwifi PTP exposes GP2-derived time, not raw TSF. Needs validation.
4. **ptp4l with many clocks** — typically used with 1-4 clocks. Need to test with 100. May need multiple instances.
5. **VIF requirement** — most drivers need an active interface for TSF ops.

Full list: [Architecture doc, Open Questions section](docs/architecture.md#open-questions--risks)

---

## License

- Kernel module (`kernel/`): GPL-2.0 (required — uses mac80211 internal APIs)
- Userspace tool (`src/`): MIT
