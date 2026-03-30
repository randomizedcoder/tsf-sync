# Options Considered & Rejected

This document records the alternatives we evaluated before settling on the PTP-based architecture. Each option is presented with its mechanism, pros/cons, and why it was rejected.

---

## Userspace TSF Access Methods

### Option A: mac80211 debugfs

**How:** Read/write `/sys/kernel/debug/ieee80211/phyN/netdev:wlanN/tsf`.

| | |
|---|---|
| **Pros** | Works for ~20 SoftMAC drivers. Zero kernel patches. Simple file I/O. |
| **Cons** | Requires root + debugfs. Not stable ABI. 10-500µs latency. No PTP integration. |
| **Status** | Available as a **fallback** for cards where `tsf-ptp` is not loaded. Not the primary path. |

### Option B: eBPF-based TSF access

**How:** Attach BPF to `get_tsf`/`set_tsf` call sites via kprobes.

| | |
|---|---|
| **Pros** | No out-of-tree module. Dynamic attach. |
| **Cons** | Can't invoke indirect function pointers. Can't acquire mac80211 locks. Verifier rejects `set_tsf` side effects. Can only observe, not act. |
| **Verdict** | **Not viable for TSF read/write.** |

### Option C: nl80211 vendor commands

**How:** `NL80211_CMD_VENDOR` with driver-specific subcommands.

| | |
|---|---|
| **Pros** | Stable netlink interface. Standard tooling. |
| **Cons** | TSF not exposed in any vendor commands. Requires kernel patches to every driver. No precedent. Same effort as PTP but without the ecosystem. |
| **Verdict** | **Not viable without kernel changes, and PTP is a better use of that effort.** |

---

## Distribution Architectures

### Option 1: Custom daemon with shared memory SeqLock + futex

**How:** Coordinator reads primary TSF, writes to a SeqLock in shared memory, wakes all worker threads via `FUTEX_WAKE(INT_MAX)`. Each worker reads the SeqLock and writes its card.

| | |
|---|---|
| **Pros** | Sub-microsecond intra-host fan-out (~100ns read, ~2µs wake-all). True broadcast. Zero-copy. Works across processes via memfd. |
| **Cons** | Custom sync protocol. Multi-host requires a separate layer (IPv6 multicast). Reinvents what PTP already does. |
| **Verdict** | **Rejected.** Elegant intra-host solution but unnecessary complexity when PTP handles the entire problem. |

### Option 2: Thread-per-card with crossbeam channels

**How:** Dedicated thread per card. Coordinator sends TSF samples via crossbeam channels.

| | |
|---|---|
| **Pros** | Simple. One slow card can't block others. |
| **Cons** | O(N) channel sends. Custom sync protocol. Multi-host needs custom solution. |
| **Verdict** | **Rejected.** Same reasons as Option 1, with worse fan-out performance. |

### Option 3: Async (tokio)

**How:** `tokio::join_all` over futures, one per card.

| | |
|---|---|
| **Pros** | Familiar Rust concurrency model. |
| **Cons** | Every TSF operation is blocking (debugfs, PTP ioctl). Each needs `spawn_blocking`. Adds async runtime complexity for zero benefit. |
| **Verdict** | **Rejected.** Wrong abstraction for blocking I/O with seconds-scale intervals. |

### Option 4: IPv6 multicast for multi-host

**How:** Coordinator multicasts `{tsf_value, ptp_timestamp}` via IPv6 multicast. Receivers reconstruct TSF using PTP-synced local clocks.

| | |
|---|---|
| **Pros** | One `sendmsg()` reaches all hosts. Natural single→multi-host transition. |
| **Cons** | Custom protocol. UDP reliability concerns. Need PTP anyway for clock agreement. |
| **Verdict** | **Superseded by PTP.** The insight that led to this option (PTP for clock agreement + multicast for data) was refined to "just use PTP for everything" — simpler, and PTP already uses multicast internally. |

---

## Linux IPC Primitives Evaluated

For the custom daemon approach (before choosing PTP), we evaluated every relevant Linux IPC primitive:

| Primitive | Latency | Fan-out | Cross-host | Why rejected |
|-----------|---------|---------|------------|-------------|
| Unix domain sockets | ~1-5µs × N | O(N) sends, no multicast | No | No broadcast. Coordinator bottleneck. |
| POSIX message queues | ~2-10µs | Competing-consumer | No | Wrong model — one reader gets each message. |
| SysV message queues | ~2-10µs | Competing-consumer | No | Same problem. Legacy API. |
| eventfd | ~0.5-2µs × N | O(N) writes | No | No broadcast. Notification only. |
| io_uring | -100-500ns overhead | Accelerator only | N/A | Not a communication primitive. |
| D-Bus / sd-bus | ~50-200µs | Broker-mediated | No | Far too slow for timing data. |
| Netlink multicast | ~5-15µs | Native multicast | No | Requires a kernel module to send from userspace. Same effort as PTP module. |
| BPF ring buffer | ~1-5µs | Competing-consumer | No | Kernel→userspace only. Wrong direction. |
| UDP broadcast | ~50-200µs | Native but imprecise | Yes (subnet) | IPv4 only. Multicast is more precise. |

The shared memory + futex SeqLock approach won this evaluation, but the entire evaluation became moot when we chose PTP — which eliminates the need for custom distribution entirely.
