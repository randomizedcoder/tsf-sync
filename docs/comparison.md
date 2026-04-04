# Comparison: tsf-sync vs FiWiTSF

This document compares two approaches to WiFi TSF synchronization across co-located access points:

- **tsf-sync** (this project) — Kernel module (PTP clock per WiFi phy) + Rust orchestrator + `phc2sys` sync loop
- **[FiWiTSF](https://git.umbernetworks.com/rjmcmahon/FiWiTSF)** — Single-file C program reading/writing TSF via mac80211 debugfs with RT scheduling

---

## Overview

| Characteristic | tsf-sync | FiWiTSF |
|----------------|----------|---------|
| **Language** | C11 (kernel module, gnu11) + Rust (userspace) | C11 (userspace only) |
| **Source LOC** | ~1,100 C (kernel) + ~2,200 Rust (userspace) | ~620 C |
| **Components** | Kernel module, Rust CLI/daemon, phc2sys, ptp4l | Single binary |
| **TSF access path** | Kernel module calls `get_tsf`/`set_tsf` via mac80211 ops directly | debugfs file I/O (`/sys/kernel/debug/ieee80211/phyN/netdev:wlanN/tsf`) |
| **Sync loop** | `phc2sys` at 10 Hz (or kernel workqueue / io_uring) | `clock_nanosleep` loop with `SCHED_FIFO` RT threads |
| **Control algorithm** | `phc2sys` PI controller + threshold filter | Proportional controller with configurable gain, optional 1D Kalman filter |
| **Multi-host** | Yes — `ptp4l` over Ethernet (IEEE 1588), no code changes | No — single-host only |
| **Driver coverage** | ~20 SoftMAC drivers + Intel native PTP | ~20 SoftMAC drivers (same debugfs interface) |
| **Build system** | Nix flake + Kbuild + Cargo | `make` (single file, no dependencies beyond libc/pthreads) |
| **Self-described scope** | Production sync infrastructure | "Experimental tooling for lab and bring-up" (per its README) |

---

## Architecture Comparison

### tsf-sync

```
  Userspace                     Kernel                        Hardware
  ─────────                     ──────                        ────────
  phc2sys ──► clock_gettime ──► PTP subsystem ──► tsf_ptp ──► get_tsf() ──► NIC
  phc2sys ◄── tsf_usec ◄────── PTP subsystem ◄── tsf_ptp ◄── TSF register
  phc2sys ──► clock_adjtime ──► PTP subsystem ──► tsf_ptp ──► set_tsf() ──► NIC
```

1. **Kernel module (`tsf-ptp`)** registers a `/dev/ptpN` PTP hardware clock for each WiFi phy that has mac80211 `get_tsf`/`set_tsf` ops.
2. **`phc2sys`** (from linuxptp) reads the master's PTP clock, compares to each secondary's PTP clock, and corrects via `clock_adjtime`. The module includes a threshold filter that skips `set_tsf` when the offset is already small, reducing PCIe traffic in steady state.
3. **Rust orchestrator (`tsf-sync`)** discovers cards via sysfs, loads the kernel module, generates `ptp4l` config, spawns `phc2sys`, and monitors health.
4. Two additional sync modes are available: an in-kernel `delayed_work` loop (Mode B) and an `io_uring` batch interface (Mode C).

### FiWiTSF

```
  Userspace (RT)                VFS / debugfs                 Hardware
  ──────────────                ─────────────                 ────────
  open() + read() ──► debugfs ──► mac80211 ──► get_tsf() ──► NIC
  parse hex string ──► compute correction
  open() + write() ──► debugfs ──► mac80211 ──► set_tsf() ──► NIC
```

1. **Single C binary** reads the master TSF from the debugfs `tsf` file (hex format), parses it, computes a proportional correction per follower (with optional Kalman filtering), and writes the corrected TSF (decimal format) back through debugfs.
2. Uses `SCHED_FIFO` real-time scheduling, `mlockall`, and optional CPU affinity to minimize jitter.
3. Two threading modes: single-threaded round-robin, or `--parallel` with `pthread_barrier`-synchronized per-follower worker threads.

---

## Summary: Pros and Cons

### tsf-sync

| Pros | Cons |
|------|------|
| Calls driver TSF ops directly — no string parsing, no VFS overhead | Requires building and loading an out-of-tree kernel module |
| Reuses battle-tested `phc2sys`/`ptp4l` for sync and multi-host | More components to deploy (kernel module + Rust binary + linuxptp) |
| Multi-host sync via PTP over Ethernet with zero code changes | Kernel module must be rebuilt per kernel version |
| Three sync modes (userspace, kernel, io_uring) for different targets | Higher initial complexity to understand the full stack |
| Threshold filter eliminates unnecessary PCIe writes in steady state | Depends on linuxptp as a runtime dependency |
| Fault-isolated: userspace crash doesn't affect kernel stability | |
| NixOS packaging, cross-compilation, MicroVM testing infrastructure | |
| Scales to 100+ cards via batch I/O (Mode C) or kernel loop (Mode B) | |

### FiWiTSF

| Pros | Cons |
|------|------|
| Single ~620-line C file — easy to read, build, and deploy | Requires `CONFIG_MAC80211_DEBUGFS` (often disabled in production kernels) |
| No kernel module needed — pure userspace | debugfs is not a stable ABI; interfaces can change between kernel versions |
| `make` builds a single binary with no external dependencies | 3+ syscalls per TSF access (open/read/close or open/write/close) + string parsing |
| Built-in proportional controller with configurable gain and optional Kalman filter | Single-host only — no multi-host path |
| Real-time scheduling (`SCHED_FIFO`) reduces timing jitter | RT scheduling requires `CAP_SYS_NICE` or root; misconfigured RT threads can starve the system |
| Good for quick lab validation and bring-up | No threshold filter — writes every cycle even when already converged |
| Barrier-synchronized parallel mode for multi-card | debugfs exposes internal kernel state (security concern on hardened systems) |

---

## Detailed Comparison

### Complexity

| Dimension | tsf-sync | FiWiTSF |
|-----------|----------|---------|
| **Total source LOC** | ~3,300 (1,100 C + 2,200 Rust) | ~620 C |
| **Number of components** | 3 (kernel module + Rust daemon + linuxptp) | 1 (single binary) |
| **Build requirements** | Kernel headers + Rust toolchain + Nix (or Cargo + Kbuild) | C compiler + make |
| **Deployment steps** | Load kernel module → start tsf-sync → phc2sys auto-spawned | `sudo ./tsf_sync_rt_starter -m ... -f ...` |
| **Configuration** | Auto-discovered via sysfs; generates ptp4l config | Manual: pass master/follower debugfs paths on command line |
| **Runtime dependencies** | linuxptp (`phc2sys`, `ptp4l`, `pmc`) | None beyond libc + pthreads |

tsf-sync is structurally more complex — it spans kernel and userspace, involves multiple processes, and requires a build toolchain for both C (kbuild) and Rust. FiWiTSF is a single compilation unit with zero external dependencies.

However, much of tsf-sync's "complexity" is delegated to upstream: `phc2sys` handles the sync algorithm, `ptp4l` handles multi-host, and the kernel's PTP subsystem handles clock registration. The custom code is a thin adapter layer.

### Simplicity

| Dimension | tsf-sync | FiWiTSF |
|-----------|----------|---------|
| **Time to understand** | Requires understanding PTP clock API, mac80211 internals, phc2sys operation | Straightforward: read file → compute → write file |
| **Time to modify sync algorithm** | Modify phc2sys config or switch to Mode B/C | Edit `apply_correction()` directly |
| **Debugging** | strace phc2sys, `pmc` tool for PTP stats, sysfs counters, journald | printf / strace on debugfs reads/writes |
| **Onboarding a new developer** | Must understand PTP ecosystem and kernel module loading | Can read and understand the entire program in one sitting |

FiWiTSF wins on approachability. A developer familiar with C and Linux can understand the entire program quickly. tsf-sync requires understanding why PTP is used as a transport mechanism and how the kernel module bridges mac80211 to the PTP subsystem.

### Risk

| Risk | tsf-sync | FiWiTSF |
|------|----------|---------|
| **Kernel stability** | Kernel module bug can panic the system. Mitigated: module is small (~1,100 LOC), uses standard PTP registration APIs, and faults are confined to the module. | No kernel module — cannot crash the kernel through this code. |
| **Fault isolation** | Userspace components (Rust daemon, phc2sys) crash independently and can be restarted by systemd. Kernel module persists across userspace restarts. | Single process — if it crashes, sync stops entirely until manually restarted. |
| **RT scheduling hazards** | phc2sys runs at normal priority. Mode B uses kernel workqueue (managed by scheduler). | `SCHED_FIFO` threads can starve the system if they spin or deadlock. `mlockall` pins all memory. Misconfiguration (wrong CPU affinity, too-short period) can make the host unresponsive. |
| **Security surface** | PTP clock devices (`/dev/ptpN`) require `CAP_SYS_RAWIO` or root. Kernel module runs in ring 0. | debugfs requires root and exposes internal kernel state. Hardened kernels (`lockdown=integrity`) disable debugfs entirely. |
| **ABI stability** | PTP clock API (`ptp_clock_info`) is a stable in-kernel interface. mac80211 `get_tsf`/`set_tsf` are internal but have been stable for 10+ years. | debugfs paths and file formats are explicitly not a stable ABI. The kernel documentation states: "There are no stability guarantees for the debugfs interface." |
| **Data integrity** | Direct function calls to `get_tsf`/`set_tsf` — no serialization/parsing. | TSF values pass through hex→string→parse→decimal→string→write pipeline. Off-by-one or format changes silently corrupt values. |

### Limitations

| Limitation | tsf-sync | FiWiTSF |
|------------|----------|---------|
| **Multi-host sync** | Supported via `ptp4l` over Ethernet | Not supported — single-host only |
| **Kernel config requirements** | Standard mac80211 (already needed for WiFi) | `CONFIG_MAC80211_DEBUGFS` must be enabled |
| **FullMAC drivers** | Not supported (firmware owns TSF) | Not supported (no debugfs TSF file) |
| **Frequency discipline** | No hardware knob on WiFi cards; `adjfine` is a no-op; time-stepping only | No frequency discipline; proportional stepping only |
| **Hot-plug** | Handled by Rust daemon — detects card add/remove via sysfs | No hot-plug support; card list fixed at startup |
| **Monitoring** | Health monitoring via `pmc`, sysfs counters, structured logging | Welford statistics printed to stdout; optional RMS warning threshold |
| **Service integration** | NixOS module, systemd unit, daemon mode | Manual foreground process |
| **Intel native PTP** | Leverages iwlwifi's built-in PTP clock directly | Cannot use — Intel cards don't expose TSF through debugfs in the same way |

---

## debugfs Dependency Analysis

FiWiTSF's architecture depends entirely on mac80211's debugfs interface. This has several implications that are critical for production use:

### Kernel configuration

`CONFIG_MAC80211_DEBUGFS` must be enabled at kernel build time. This option is:

- **Disabled by default** in many distribution kernels (Debian, Ubuntu server, RHEL) as it is a debugging aid, not a production feature.
- **Disabled by hardened kernels** — `lockdown=integrity` (enabled by Secure Boot) prevents debugfs access entirely.
- **Not guaranteed to exist** — kernel packagers may strip debugfs support to reduce attack surface.

Enabling it requires a custom kernel build, which undermines FiWiTSF's simplicity advantage for production deployments.

### Security

debugfs exposes internal kernel data structures to userspace. The kernel documentation explicitly warns:

> "Debugfs is typically mounted at `/sys/kernel/debug`. It should not be used for anything that needs to be available to non-privileged users."

On systems where debugfs is available, any root process can read internal mac80211 state — not just TSF values. This is a broader exposure than PTP clock devices, which provide only the clock interface.

### Performance overhead per TSF access

Each TSF read or write through debugfs requires:

1. **`open()`** — VFS path lookup, dentry allocation, file descriptor allocation
2. **`read()`/`write()`** — VFS dispatch → debugfs handler → mac80211 mutex acquisition → driver `get_tsf`/`set_tsf` call → format conversion (hex↔decimal string) → copy_to_user/copy_from_user
3. **`close()`** — file descriptor release, dentry reference drop

That is **3 syscalls + string formatting + VFS overhead per TSF access**. For a single sync cycle with N followers:

- **FiWiTSF**: `3 × (1 master read + N follower reads + N follower writes) = 3 × (1 + 2N)` syscalls, plus hex/decimal string parsing for every value
- **tsf-sync (Mode A)**: `2N + 2` ioctls (clock_gettime + clock_adjtime per card), no string conversion
- **tsf-sync (Mode C)**: 2 syscalls total (one batch read, one batch write), regardless of N

### Contention under scale

The debugfs `tsf` file handler acquires the mac80211 `wiphy_lock` mutex for each access. With many cards accessed in rapid succession, this creates serialized access through a single lock per phy. The PTP path acquires the same underlying lock (it must — `get_tsf`/`set_tsf` require it), but avoids the VFS and formatting overhead surrounding each lock acquisition.

### Not a stable ABI

The kernel's debugfs documentation is explicit: debugfs interfaces can change without notice between kernel versions. File paths, formats, and availability are internal implementation details. tsf-sync's `options-considered.md` evaluated debugfs as "Option A" and relegated it to fallback status for this reason.

---

## Scaling Analysis

### 24 cards (current hardware)

| Metric | tsf-sync (Mode A) | FiWiTSF (single-threaded) |
|--------|-------------------|---------------------------|
| Syscalls per cycle | 48 (2 × 23 + 2) | 141 (3 × (1 + 2×23)) |
| String conversions | 0 | 47 (1 master + 23 reads + 23 writes) |
| PCIe transactions (converging) | 70 (1 + 3×23) | 47 (1 + 2×23) |
| PCIe transactions (steady state) | 24 (1 + 23, threshold skips writes) | 47 (no threshold — always writes) |

Both approaches work at this scale. tsf-sync's threshold filter reduces steady-state PCIe traffic by ~50%. FiWiTSF's syscall overhead is manageable.

### 60 cards

| Metric | tsf-sync (Mode A) | tsf-sync (Mode C) | FiWiTSF (parallel) |
|--------|-------------------|--------------------|---------------------|
| Syscalls per cycle | 120 (2 × 59 + 2) | 2 | 357 (3 × (1 + 2×59)) |
| Threads | 1 (phc2sys) | 1 (io_uring) | 60 (1 sampler + 59 workers) |
| String conversions | 0 | 0 | 119 |
| PCIe (steady state) | 60 | 60 | 119 |

At 60 cards, FiWiTSF's parallel mode spawns 60 RT threads. Each thread requires stack allocation, scheduling overhead, and barrier synchronization. The 357 syscalls per cycle (at 10 Hz = 3,570/sec) and string parsing become measurable. tsf-sync Mode C reduces to 2 syscalls regardless of card count.

### 100+ cards

| Concern | tsf-sync | FiWiTSF |
|---------|----------|---------|
| **Syscalls** | Mode C: 2 per cycle. Mode A: 202. | 603 per cycle (3 × (1 + 2×100)) |
| **Threads** | 1 (any mode) | 101 RT threads in parallel mode |
| **Memory** | Kernel module: per-card struct (~200 bytes each). Rust: heap-allocated Vec. | 101 thread stacks (default 8 MB each = ~800 MB virtual, ~101 pages physical with `mlockall`) |
| **Scheduler pressure** | Normal priority or kworker | 101 `SCHED_FIFO` threads competing for CPU time |
| **debugfs contention** | N/A | 603 open/read-or-write/close sequences per cycle through VFS |
| **Cycle time budget** | 100 ms cycle: ~1 ms for 100 ioctls | 100 ms cycle: risk of overrun from VFS + string parsing + RT scheduling |

At 100+ cards, FiWiTSF's approach faces significant pressure: hundreds of RT threads, hundreds of file operations per cycle, and VFS contention. tsf-sync's batch I/O (Mode C) or kernel loop (Mode B) scales linearly without increasing syscall count or thread count.

---

## Benchmark Results

### All sync modes at a glance

The benchmark harness tests all 5 synchronization paths in a single microVM:

| Mode | Binary | TSF access path | Syscalls per cycle (N followers) |
|------|--------|-----------------|----------------------------------|
| **A** phc2sys | `tsf-sync` | PTP clock ioctls | 2N + 2 |
| **B** kernel | `tsf-sync` | In-kernel `delayed_work` | 0 (kernel-only) |
| **C** io\_uring | `tsf-sync` | Batch `/dev/tsf_sync` | 2 (regardless of N) |
| **D** Rust debugfs | `tsf-sync-debugfs` | `pread`/`pwrite` on debugfs | 2N + 2 |
| **E** C debugfs | FiWiTSF | `open`/`read`/`close` on debugfs | 6N + 4 |

### Debugfs syscall comparison: Rust (D) vs C (E)

`tsf-sync-debugfs` reimplements FiWiTSF's debugfs approach with cached file descriptors (`pread`/`pwrite`, 1 syscall each) instead of `open`/`read`/`close` (3 syscalls each), plus SSSE3 SIMD hex parsing and inline `syscall` instructions (bypassing libc PLT).

| | Master read | N follower reads | N follower writes | Sleep | Total |
|---|---|---|---|---|---|
| **C (FiWiTSF)** | 3 | 3N | 3N | 1 | 6N + 4 |
| **Rust (pread/pwrite)** | 1 | N | N | 1 | 2N + 2 |

| Radios | C syscalls/cycle | Rust syscalls/cycle | Reduction |
|--------|-----------------|--------------------:|----------:|
| 4 | 22 | 8 | 2.8x |
| 24 | 148 | 50 | 3.0x |
| 100 | 604 | 202 | 3.0x |

### How to run

```bash
# Quick benchmark (4 radios, 30s)
nix run .#tsf-sync-benchmark-4

# Full scale (24 radios, 60s)
nix run .#tsf-sync-benchmark-24

# Stress test (100 radios, 60s)
nix run .#tsf-sync-benchmark-100

# All radio counts sequentially
nix run .#tsf-sync-benchmark-all
```

The benchmark runs all 5 sync modes (phc2sys, kernel, io\_uring, Rust debugfs, C debugfs) inside a microVM with `mac80211_hwsim`, collecting `strace -c` syscall counts, `/usr/bin/time -v` resource stats, and `perf stat` counters when available.

### Measured results

*TODO: Fill in after running `nix run .#tsf-sync-benchmark-all` on target hardware.*

---

## Conclusion

**FiWiTSF** is well-suited for:
- Lab bring-up and quick validation with a small number of cards
- Environments where building/loading a kernel module is not feasible
- One-off testing where simplicity and speed of deployment matter most
- Systems where `CONFIG_MAC80211_DEBUGFS` is already enabled

**tsf-sync** is designed for:
- Production deployments where debugfs may not be available or desirable
- Scaling to 60-100+ cards per host with controlled overhead
- Multi-host synchronization across Ethernet (via PTP)
- Long-running operation with health monitoring, hot-plug, and service integration
- Environments requiring stable kernel interfaces (PTP clock API vs debugfs)

The two projects occupy different points in the design space. FiWiTSF optimizes for minimal deployment friction at small scale. tsf-sync optimizes for production robustness, scaling, and ecosystem integration — at the cost of a more involved initial setup. FiWiTSF's own README acknowledges this positioning: "Experimental tooling for lab and bring-up. Production systems often replace debugfs with a dedicated kernel interface or driver hook."
