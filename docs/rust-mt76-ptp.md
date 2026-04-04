# Feasibility Study: Rust mt76 WiFi Driver

Can the mt76 WiFi driver — or meaningful subsystems of it — be reimplemented in Rust using the Rust-for-Linux (R4L) framework? This study evaluates every major mt76 subsystem against the R4L abstractions available in Linux 6.18/6.19 stable.

**Target:** Linux 6.18/6.19 stable

**Starting point:** No Rust kernel code exists in this project — the kernel side is pure C, Rust is userspace only. No Rust abstractions exist upstream for the PTP clock API (`ptp_clock_kernel.h`), WiFi/mac80211 subsystems, or DMA engine APIs.

---

## 1. mt76 Driver Architecture

mt76 is the upstream Linux WiFi driver for MediaTek 802.11 chipsets. It's a SoftMAC driver — the host CPU handles 802.11 MAC-layer logic via the mac80211 subsystem, while the hardware handles PHY-layer operations.

### Subsystems

```
mt76/
├── Core infrastructure       mt76_dev, bus abstractions, module init
├── mac80211 interface        ieee80211_ops callbacks (~30 ops)
├── TX path                   Queue management, DMA ring submission, aggregation
├── RX path                   DMA ring reaping, page_pool, status parsing
├── DMA engine                Ring descriptors, buffer management, WED offload
├── Firmware / MCU            Firmware loading, MCU command/event protocol
├── PTP clock                 TSF-as-PTP via ptp_clock_kernel.h (our patch)
├── Per-chipset glue          mt7915/, mt7921/, mt7996/ — registers, init, quirks
├── Bus transports            PCI, USB, SDIO probe/remove/power
├── LED control               led_classdev for activity indicators
└── Testmode / debugfs        NL80211 testmode, debugfs stats
```

### Scale

| Metric | Approximate |
|---|---|
| Total C lines (mt76/ tree) | ~60,000 |
| Per-chipset dirs (mt7915, mt7921, mt7996) | ~8,000-15,000 each |
| Common core (mt76.h, mac80211.c, dma.c, etc.) | ~10,000 |
| mac80211 callback implementations | ~30 ops |
| Supported chipsets | MT7615, MT7915/7916/7986, MT7921/7922/7925, MT7996 |

### Chipset diversity

The driver's central challenge is hardware diversity. A single `mt76_dev` base struct serves all chipsets, with per-chipset differences handled via:

| Chipset family | TSF access | Bus | Firmware model |
|---|---|---|---|
| MT7915/7916/7986 | Direct MMIO registers (`MT_LPON_UTTR0/UTTR1`) | PCIe | Embedded MCU |
| MT7996 | Direct MMIO registers | PCIe | Embedded MCU |
| MT7921/7922/7925 | MCU firmware commands | PCIe/USB | Host-loaded firmware |

Register-based chipsets have 1-10 us TSF latency; firmware-based chipsets have 10-500 us.

---

## 2. R4L Abstractions Inventory (6.18/6.19)

Mapping C kernel facilities used across the mt76 driver to their R4L equivalents:

### Available

| C Facility | R4L Abstraction | Status | Used by |
|---|---|---|---|
| `mutex_lock`/`unlock` | `kernel::sync::Mutex<T>` + RAII guard | Stable since 6.1 | All subsystems |
| `spinlock_t` | `kernel::sync::SpinLock<T>` | Stable since 6.1 | IRQ handling, queues |
| `struct module` | `kernel::module!` macro | Stable | Module init |
| `struct device` | `kernel::device::Device` | Present, refined in 6.18 | Core |
| `readl`/`writel` (MMIO) | `kernel::io::Mmio<SIZE>` | Present in 6.18+ | Register-based chipsets |
| PCI driver registration | `kernel::pci::Driver` trait | Merged in 6.18 | Bus transport |
| `container_of` | `kernel::container_of!` macro | Present | PTP, device lookup |
| `ktime_get_raw`/`ktime_get_real` | `kernel::time::Instant::now()` | Present in 6.18+ | PTP crosststamp |
| `hrtimer` | `kernel::time::hrtimer` | Present in 6.18 | Timers |
| `IS_ERR`/`PTR_ERR` | `Result<T, Error>` | Present | All subsystems |
| `printk`/`dev_info` | `kernel::pr_info!`/`dev_info!` | Present | All subsystems |
| `CONFIG_*` guards | `#[cfg(CONFIG_...)]` | Present | Conditional compilation |
| `workqueue` | `kernel::workqueue::WorkQueue` | Present in 6.7+ | Deferred work |
| `alloc`/`kzalloc` | `kernel::alloc::KBox<T>` | Present | Memory allocation |
| `firmware_request` | `kernel::firmware::Firmware` | Present in 6.18+ | Firmware loading |

### Not available

| C Facility | Used by | R4L Status |
|---|---|---|
| `ptp_clock_kernel.h` | PTP subsystem | **No abstraction** |
| `net/mac80211.h` (`ieee80211_ops`) | mac80211 interface | **No abstraction** |
| `cfg80211` / `nl80211` | Configuration | **No abstraction** |
| DMA ring management | TX/RX paths | **No abstraction** (generic DMA mapping exists, but not ring descriptors) |
| `page_pool` | RX buffer management | **No abstraction** |
| `sk_buff` / `skb` | Packet buffers | **No abstraction** |
| `napi_struct` / NAPI polling | RX processing | **No abstraction** |
| `led_classdev` | LED control | **No abstraction** |
| USB / SDIO driver APIs | Bus transports | **No abstraction** (PCI only) |
| `netlink` / `nl80211` | Userspace config | **No abstraction** |

---

## 3. Per-Subsystem Feasibility

### 3.1 PTP Hardware Clock

**Our 142-line C patch** (`patches/mt76/0001-wifi-mt76-add-ptp-hardware-clock-for-tsf.patch`). Self-contained, additive, does not touch TX/RX paths.

| Aspect | Assessment |
|---|---|
| Blocking gap | PTP clock abstraction (~300-400 lines to create) |
| R4L readiness | Everything except PTP API is covered |
| Safety benefit | High — RAII mutex, `Option<T>` for callbacks, `Result` for errors, `Drop` for cleanup |
| Unsafe surface | ~8-10 discrete blocks: `container_of`, FFI to `ptp_ops` callbacks, ktime accessors |
| Effort | 3-5 weeks (including reusable PTP abstraction) |
| Lines | 142 C -> ~400-520 Rust (300-400 reusable abstraction + 80-120 mt76 module) |

**PTP trait sketch:**

```rust
pub trait PtpClockOps {
    fn gettime64(&self) -> Result<Timespec64>;
    fn settime64(&self, ts: &Timespec64) -> Result;
    fn adjtime(&self, delta_ns: i64) -> Result;
    fn adjfine(&self, _scaled_ppm: i64) -> Result { Ok(()) }
    fn getcrosststamp(&self) -> Result<CrossTimestamp> { Err(EOPNOTSUPP) }
}
```

**Verdict: Feasible.** Single blocking gap (PTP abstraction) is bounded and reusable. Best candidate for an incremental Rust port.

### 3.2 Core Infrastructure (`mt76_dev`, module init)

The `mt76_dev` struct (~300 fields across base + per-chipset extensions) is the central data structure. Module initialization sets up the device, allocates queues, and registers with mac80211.

| Aspect | Assessment |
|---|---|
| Blocking gap | mac80211 abstraction (massive — `ieee80211_ops` has ~30 callbacks) |
| R4L readiness | Device model and PCI ready; mac80211 is the wall |
| Safety benefit | Medium — struct init is already well-understood in C, but Rust prevents field-init bugs |
| Effort | Cannot be ported without mac80211 abstraction |

**Verdict: Blocked.** `mt76_dev` is tightly coupled to mac80211. Porting the core means porting (or wrapping) the entire mac80211 interface. Estimated ~3,000-5,000 lines for a mac80211 Rust abstraction alone — a multi-year effort that doesn't exist on anyone's roadmap.

### 3.3 TX Path

Queue selection, SKB manipulation, DMA descriptor writing, A-MPDU aggregation setup, rate table management. Hot path — called for every outgoing frame.

| Aspect | Assessment |
|---|---|
| Blocking gaps | `sk_buff`, DMA ring, mac80211 TX status, `page_pool` |
| R4L readiness | None of the networking data structures are wrapped |
| Safety benefit | High in theory — DMA ring corruption and use-after-free are real bug classes |
| Performance sensitivity | **Critical** — any overhead in per-packet path is unacceptable |
| Effort | Requires `sk_buff` + DMA ring + NAPI abstractions first |

**Verdict: Blocked.** Requires foundational networking abstractions that don't exist. The `sk_buff` abstraction alone is one of the most debated topics in R4L — it touches every networking subsystem.

### 3.4 RX Path

DMA ring reaping, page_pool buffer recycling, SKB construction, mac80211 RX status parsing, NAPI poll integration.

| Aspect | Assessment |
|---|---|
| Blocking gaps | Same as TX: `sk_buff`, DMA ring, NAPI, `page_pool` |
| R4L readiness | None available |
| Safety benefit | High — RX buffer management is a common source of use-after-free and double-free bugs |
| Performance sensitivity | **Critical** — NAPI poll budget is the throughput bottleneck |

**Verdict: Blocked.** Same dependencies as TX. Cannot be ported independently.

### 3.5 DMA Engine

Ring descriptor management, buffer allocation, WED (Wireless Ethernet Dispatcher) hardware offload for MT7915/MT7996.

| Aspect | Assessment |
|---|---|
| Blocking gaps | DMA ring abstraction, `page_pool`, WED SoC interface |
| R4L readiness | Basic `dma_alloc_coherent` exists; ring management does not |
| Safety benefit | **Very high** — DMA descriptor corruption causes hard-to-debug data corruption and crashes |
| Effort | ~2,000-3,000 lines for a DMA ring abstraction; WED adds SoC-specific complexity |

**Verdict: Blocked.** DMA ring abstraction is a prerequisite for TX/RX. It's also driver-specific enough that a generic R4L abstraction may not be the right approach — mt76's rings differ from other drivers.

### 3.6 Firmware / MCU Command Interface

Firmware binary loading, MCU command/event serialization, timeout handling, firmware version negotiation. Used by MT7921/MT7925 for everything including TSF access.

| Aspect | Assessment |
|---|---|
| Blocking gaps | Firmware request API exists in R4L (6.18+); MCU protocol is driver-internal |
| R4L readiness | Partial — `kernel::firmware::Firmware` handles loading; command protocol is custom |
| Safety benefit | Medium — command serialization bugs exist but are caught by firmware-side validation |
| Effort | ~1,000-2,000 lines; heavily chipset-specific |

**Verdict: Partially feasible.** Firmware loading could use the R4L `Firmware` abstraction. The MCU command protocol is proprietary and driver-internal — it could be written in Rust, but depends on the core `mt76_dev` infrastructure being available.

### 3.7 Per-Chipset Implementations (mt7915/, mt7921/, mt7996/)

Register maps, init sequences, calibration, chipset-specific quirks. Each chipset directory is 8,000-15,000 lines of C.

| Aspect | Assessment |
|---|---|
| Blocking gaps | All of the above — chipset code touches every subsystem |
| R4L readiness | MMIO registers are wrapped; everything else is not |
| Safety benefit | Low to medium — most chipset code is well-tested init sequences |
| Effort | ~8,000-15,000 lines per chipset, assumes all dependencies exist |

**Verdict: Blocked.** Per-chipset code cannot be ported without the core infrastructure and all subsystem abstractions.

### 3.8 Bus Transports (PCI, USB, SDIO)

Probe/remove lifecycle, power management, bus-specific I/O.

| Aspect | Assessment |
|---|---|
| Blocking gaps | USB and SDIO abstractions don't exist in R4L |
| R4L readiness | PCI: ready (6.18). USB: not available. SDIO: not available. |
| Safety benefit | Medium — probe/remove lifecycle bugs (use-after-free on disconnect) are a real class |
| Effort | PCI transport alone: ~500-800 lines; USB/SDIO: blocked |

**Verdict: PCI feasible, USB/SDIO blocked.** The PCI transport could be ported using the `kernel::pci::Driver` trait from 6.18, but it depends on the core `mt76_dev` infrastructure.

### Summary

| Subsystem | Feasible? | Blocking gaps | Est. effort |
|---|---|---|---|
| **PTP clock** | **Yes** | PTP abstraction (300-400 lines) | 3-5 weeks |
| Core infrastructure | No | mac80211 abstraction | Multi-year |
| TX path | No | sk_buff, DMA, mac80211 TX | Multi-year |
| RX path | No | sk_buff, DMA, NAPI, page_pool | Multi-year |
| DMA engine | No | DMA ring abstraction | Months |
| Firmware / MCU | Partially | Core infrastructure | Months |
| Per-chipset glue | No | All of the above | Multi-year |
| PCI transport | Partially | Core infrastructure | Weeks |
| USB / SDIO transport | No | USB/SDIO abstractions | Unknown |

---

## 4. Architecture Options

### Option A (Recommended): PTP-only — Rust PTP Abstraction + Rust mt76 PTP Module

- **Phase 1:** Reusable `rust/kernel/ptp.rs` wrapping `ptp_clock_kernel.h` (~300-400 lines)
- **Phase 2:** `drivers/net/wireless/mediatek/mt76/ptp.rs` implementing `PtpClockOps` (~80-120 lines)
- mt76 PTP module calls C `ptp_ops->tsf_read()`/`tsf_write()` callbacks via FFI
- Follows the PHY abstraction + ASIX PHY driver precedent

The only subsystem where the value/effort ratio is favorable today.

### Option B: Incremental — Rust islands in a C driver

Port individual subsystems to Rust while keeping the rest in C, connected via FFI. Order:
1. PTP (smallest, self-contained)
2. PCI transport (R4L abstractions exist)
3. Firmware loading (partial R4L support)
4. Wait for mac80211/sk_buff/DMA abstractions, then reassess

This is how the Nova GPU driver and Binder are approaching Rust adoption. Practical, but each "island" has FFI overhead and the safety boundary is at the FFI seam — bugs in the C side still corrupt the Rust side's assumptions.

### Option C: Full Rust rewrite

Rewrite the entire ~60,000-line mt76 driver in Rust.

**Rejected.** Requires mac80211, cfg80211, sk_buff, NAPI, DMA, page_pool, USB, and SDIO Rust abstractions — none of which exist. The WiFi subsystem is one of the most complex in the kernel, with no R4L activity. A full rewrite is a multi-year, multi-team effort that depends on foundational R4L work that hasn't started. No WiFi driver (of any vendor) has been ported to Rust or is on a public roadmap to be ported.

### Option D: Wait for R4L WiFi progress

Do nothing now. Submit the C patches upstream. Monitor R4L mailing lists for mac80211 or networking abstraction RFCs. Revisit when the ecosystem catches up.

This is not inaction — it's the rational default given the gap between what R4L provides and what a WiFi driver needs.

---

## 5. Safety Analysis

### What Rust fixes across the full driver

If all subsystems could be ported, these bug classes would be eliminated or reduced:

| Bug class | Where it occurs in mt76 | What Rust provides |
|---|---|---|
| Mutex unlock forgetting | All subsystems (`dev->mutex`, `ar->conf_mutex`) | RAII `MutexGuard` — unlock on drop, always |
| Null pointer dereference | Optional callbacks (`ptp_ops`, chipset-specific ops) | `Option<T>` — compile-time enforcement |
| Uninitialized struct fields | Device init, per-chipset setup | Struct literals — all fields or compile error |
| Use-after-free on device disconnect | USB hot-unplug, PCI remove | Lifetime tracking, `Arc<T>` reference counting |
| DMA buffer use-after-free | TX/RX ring management | Ownership model prevents aliased mutable access |
| Double-free on error paths | Firmware loading, DMA allocation | `Drop` trait — single owner, freed once |
| Integer overflow in size calculations | DMA buffer sizing, SKB allocation | Checked arithmetic, `usize` bounds |
| Missing error checks | `IS_ERR` results from registration APIs | `Result<T, Error>` — must handle or propagate |

### What Rust does NOT fix

| Issue | Why Rust doesn't help |
|---|---|
| Firmware bugs | Firmware is a black box; MCU command protocol is trust-based |
| Hardware register semantics | Writing the wrong value to the right register is a logic bug, not a type error |
| Concurrency design (deadlocks) | Rust prevents data races, not deadlocks — lock ordering is still manual |
| mac80211 protocol correctness | State machine logic bugs are the same in any language |
| Performance regressions | Rust doesn't cause them, but doesn't prevent algorithmic inefficiency |

### PTP-specific safety analysis (what we can actually port today)

**Fully safe in Rust (~80-90 lines):** mutex locking, TSF us/ns conversion, `timespec64` conversion, error returns, null/option checks, struct initialization, conditional compilation.

**Unsafe-but-bounded (~8-10 blocks):** `container_of` from `ptp_clock_info`, FFI to `ptp_ops->tsf_read()`/`tsf_write()`, ktime accessors, `dev->dev` and `dev->hw->wiphy` access.

**Eliminated by PTP abstraction:** `ptp_clock_register()`/`unregister()` wrapped in RAII, function pointer dispatch replaced by trait vtable.

---

## 6. Effort Estimate

### PTP-only (Option A)

| Phase | Deliverable | Effort | Lines |
|---|---|---|---|
| 1 | Rust PTP clock abstraction (`rust/kernel/ptp.rs`) | 2-3 weeks | 300-400 |
| 2 | Rust mt76 PTP module (`drivers/.../mt76/ptp.rs`) | 1-2 weeks | 80-120 |
| 3 | Nix build + test integration (`CONFIG_RUST=y` kernel) | 1 week | Nix only |
| 4 | Upstream submission (RFC, review cycles) | 2-4 weeks | Polish |
| **Total** | | **6-10 weeks** | **~400-520** |

142 lines of C becomes ~400-520 lines of Rust. ~300-400 are the reusable PTP abstraction benefiting all future Rust PTP drivers.

### Incremental (Option B)

| Phase | Deliverable | Effort | Depends on |
|---|---|---|---|
| 1 | PTP (as above) | 6-10 weeks | PTP abstraction |
| 2 | PCI transport wrapper | 2-4 weeks | Core mt76_dev available via `Opaque<T>` |
| 3 | Firmware loading | 4-8 weeks | Core infrastructure |
| 4+ | TX/RX/DMA | **Blocked** | sk_buff, NAPI, DMA ring, page_pool abstractions |

Phases 1-3 are feasible within a year. Phase 4+ depends on R4L ecosystem progress outside our control.

### Full rewrite (Option C)

| Component | Est. Rust lines | Depends on |
|---|---|---|
| mac80211 abstraction | 3,000-5,000 | Upstream R4L WiFi effort (does not exist) |
| sk_buff abstraction | 1,000-2,000 | Upstream R4L networking effort |
| DMA ring abstraction | 1,000-2,000 | Upstream R4L DMA effort |
| mt76 core | 5,000-8,000 | All of the above |
| Per-chipset (x3) | 8,000-15,000 each | Core |
| **Total** | **~30,000-50,000** | **Multi-year, multi-team** |

**Reference points:**
- The R4L PHY abstraction took ~3 months from RFC to merge (~500 lines)
- The R4L PCI abstraction took ~4 months of review
- The Nova GPU driver (the most ambitious R4L effort) focuses on PCI + MMIO + firmware, avoiding the networking stack entirely

---

## 7. Risk Assessment

| Risk | Level | Mitigation |
|---|---|---|
| R4L API instability between kernel versions | Medium | Pin to specific version — same strategy as C patches |
| Upstream acceptance of PTP Rust abstraction | **High** | No precedent; Richard Cochran (PTP maintainer) receptiveness unknown |
| mac80211 Rust abstraction never materializes | **High** | No one is working on it; WiFi is not on the R4L roadmap |
| Build complexity (`CONFIG_RUST=y` required) | Medium | Separate Nix build path with Rust-enabled kernel config |
| Testing regression | Low | MicroVM tests are language-agnostic |
| Performance | Low (PTP), Medium (TX/RX) | PTP is off hot path; TX/RX would need benchmarking |
| Cross-subsystem merge coordination | Medium | Submit PTP abstraction first, mt76 module next cycle |
| Maintaining mixed C/Rust driver | Medium | FFI boundary is a maintenance burden; both languages must be understood |

---

## 8. Recommendation

### PTP subsystem

**Feasible today, but premature.** The C patch works, is 142 lines, and is ready for upstream submission. The Rust version requires 6-10 weeks, produces a reusable PTP abstraction, but faces uncertain upstream acceptance.

**Proceed when:**
- PTP subsystem maintainer expresses interest in Rust abstractions
- Another Rust driver needs PTP support (Nova GPU, future Rust NIC)
- mt76 begins a broader Rust port

### Broader mt76 driver

**Not feasible today.** The mac80211, sk_buff, DMA, NAPI, and page_pool abstractions required to port the core data paths do not exist in R4L and are not on any public roadmap. A WiFi driver is among the most abstraction-dependent code in the kernel — it sits at the intersection of networking, bus management, firmware, and the 802.11 state machine.

**Proceed when:**
- R4L ships `sk_buff` and NAPI abstractions (unlocks networking drivers broadly)
- An R4L mac80211/cfg80211 abstraction RFC appears on netdev@
- A simpler WiFi driver (e.g., a virtual/test driver) is ported to Rust as a proof of concept

### Recommended next step

Submit the C patches upstream. Monitor R4L progress on `rust-for-linux@vger.kernel.org` and `netdev@vger.kernel.org`. The PTP abstraction is a good "first contribution" if R4L PTP interest emerges — small, self-contained, reusable, and not performance-critical.
