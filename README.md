# tsf-sync

Bridge WiFi TSF (Timing Synchronization Function) into the Linux PTP (Precision Time Protocol) subsystem, enabling standard PTP infrastructure (`ptp4l`, `phc2sys`) to synchronize TSF across any number of WiFi cards and hosts.

**Approach:** Make every WiFi card look like a PTP hardware clock (`/dev/ptpN`). Let the mature, battle-tested PTP ecosystem handle synchronization — from a single host up to datacenter-scale multi-host deployments.

**Current hardware:** 24 WiFi cards (Intel AX210 + MediaTek MT7925), scaling to 60-100+ per host, multiple hosts.

---

## How It Works

Intel's `iwlwifi` driver already exposes its WiFi TSF as a PTP hardware clock. Our job is to extend this pattern to every other WiFi driver — about 20 Linux SoftMAC drivers gain PTP support through a single kernel module.

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                      PTP Domain                                 │
 │                                                                 │
 │   Upstream PTP         ┌──────────┐        Upstream PTP         │
 │   Grandmaster ────────►│  ptp4l   │◄─────── Grandmaster         │
 │   (GPS, atomic,        │          │         (or another host)   │
 │    or NIC PHC)         └────┬─────┘                             │
 │                             │                                   │
 │               ┌─────────────┼─────────────┐                     │
 │               │             │             │                     │
 │          /dev/ptp0     /dev/ptp1     /dev/ptpN                  │
 │          (Intel)       (MediaTek)   (any card)                  │
 │          iwlwifi       tsf-ptp      tsf-ptp                     │
 │          native        module       module                      │
 │               │             │             │                     │
 │           ┌───┴───┐    ┌────┴────┐   ┌────┴────┐               │
 │           │phy0   │    │phy1     │   │phyN     │               │
 │           │AX210  │    │MT7925   │   │any card │               │
 │           └───────┘    └─────────┘   └─────────┘               │
 └─────────────────────────────────────────────────────────────────┘

 Single host: ptp4l syncs all /dev/ptpN clocks to one primary.
 Multi-host:  ptp4l syncs across hosts over Ethernet — same protocol, same config.
```

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

### Why PTP?

We write ~500 lines of kernel C + ~2000 lines of Rust. We get single-host sync, multi-host sync, GPS/atomic clock input, system clock integration, sub-µs accuracy, and standard monitoring — all from the existing PTP ecosystem. See [Architecture & Design Rationale](docs/architecture.md) for the full evaluation of alternatives.

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
│   ├── devshell.nix                   # Development shell
│   ├── ci.nix                         # CI checks
│   └── module.nix                     # NixOS service module
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
| [Architecture & Design Rationale](docs/architecture.md) | Core insight, why PTP, what we build vs upstream | Complete |
| [Driver Compatibility Survey](docs/driver-survey.md) | TSF/PTP support across all Linux WiFi drivers | Complete |
| [Kernel Module: tsf-ptp](docs/kernel-module.md) | Module design, PTP↔mac80211 mapping, challenges | Complete |
| [Userspace Tool: tsf-sync](docs/userspace-tool.md) | CLI, daemon mode, discovery, config generation | Complete |
| [PTP Topology & Scaling](docs/ptp-topology.md) | Single-host, multi-host, GPS input configurations | Complete |
| [Testing Strategy](docs/testing.md) | mac80211_hwsim, integration tests, test matrix | Complete |
| [Error Handling](docs/error-handling.md) | Error classification, health state machine, monitoring | Complete |
| [Options Considered](docs/options-considered.md) | Alternatives evaluated and why they were rejected | Complete |
| [Deployment Guide](docs/deployment.md) | NixOS module, DKMS, manual setup | Placeholder — Phase 1 |
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
