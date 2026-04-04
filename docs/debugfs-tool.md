# Debugfs Sync Tool: `tsf-sync-debugfs`

A standalone Rust binary that synchronizes WiFi TSF across co-located radios via mac80211's debugfs interface. Reimplements [FiWiTSF](https://git.umbernetworks.com/rjmcmahon/FiWiTSF)'s approach with three key optimizations: cached file descriptors, inline syscalls, and SIMD hex parsing.

This is **Mode D** in the sync mode comparison — a pure-userspace alternative that requires no kernel module, only `CONFIG_MAC80211_DEBUGFS`.

---

## Architecture

```
  tsf-sync-debugfs (one process, SCHED_FIFO)
  ┌──────────────────────────────────────────────────────────────────────┐
  │                                                                      │
  │  ┌─ Startup ───────────────────────────────────────────────────────┐ │
  │  │  CLI parse → open TsfFile handles → setup RT → install signals │ │
  │  └─────────────────────────────────────────────────────────────────┘ │
  │                          │                                           │
  │              ┌───────────┴───────────┐                               │
  │              │   --parallel flag?    │                               │
  │              └───┬──────────────┬────┘                               │
  │            no    │              │   yes                               │
  │                  ▼              ▼                                     │
  │  ┌──────────────────┐  ┌───────────────────┐                        │
  │  │  run_single()    │  │  run_parallel()   │                        │
  │  │  Round-robin:    │  │  Barrier-synced:  │                        │
  │  │  master read     │  │  sampler thread   │                        │
  │  │  for each follower: │  N worker threads │                        │
  │  │    read → correct │  │  AtomicU64 master│                        │
  │  │    → write → stats│  │  2× Barrier sync │                        │
  │  │  sleep_until     │  │  sleep_until     │                        │
  │  └──────────────────┘  └───────────────────┘                        │
  │                                                                      │
  │  ┌─ Per-follower correction (shared by both modes) ────────────────┐ │
  │  │  pread(follower) → Controller::apply(master, follower) →        │ │
  │  │  pwrite(follower + step) → WelfordStats::update(err, step)      │ │
  │  └─────────────────────────────────────────────────────────────────┘ │
  └──────────────────────────────────────────────────────────────────────┘

  I/O path (x86_64):
    read_tsf:  syscall(17)  → pread64(fd, buf, 64, 0) → SIMD hex parse
    write_tsf: format_u64_decimal → syscall(18) → pwrite64(fd, buf, len, 0)
    sleep:     syscall(230) → clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)
```

---

## Key Optimization: Cached File Descriptors

FiWiTSF does `open()`/`read()`/`close()` (3 syscalls) per TSF access. We open each debugfs file once at startup, cache the `OwnedFd`, and use `pread()`/`pwrite()` (1 syscall each).

| | Master read | N follower reads | N follower writes | Sleep | Total |
|---|---|---|---|---|---|
| **FiWiTSF (C)** | 3 | 3N | 3N | 1 | 6N + 4 |
| **tsf-sync-debugfs (Rust)** | 1 | N | N | 1 | 2N + 2 |

| Radios | C syscalls/cycle | Rust syscalls/cycle | Reduction |
|--------|:----------------:|:-------------------:|:---------:|
| 4 | 22 | 8 | 2.8x |
| 24 | 148 | 50 | 3.0x |
| 100 | 604 | 202 | 3.0x |

---

## Module Structure

```
src/bin/tsf_sync_debugfs/
├── main.rs          # Entry point: CLI → open handles → RT setup → dispatch
├── cli.rs           # Clap argument parsing (mirrors FiWiTSF's options)
├── debugfs.rs       # TsfFile: cached fd, read_raw/write_raw, read_tsf/write_tsf
├── asm/             # Architecture-specific hot-path optimizations
│   ├── mod.rs       # Re-exports
│   ├── syscall.rs   # Inline x86_64 syscall wrappers (pread64, pwrite64, clock_nanosleep)
│   └── hex.rs       # SSSE3 SIMD hex parser + scalar fallback
├── control.rs       # Proportional controller + optional 1D Kalman filter
├── stats.rs         # Welford online statistics (RMS, mean, max)
├── rt.rs            # RT scheduling: mlockall, SCHED_FIFO, CPU affinity, sleep_until
├── signal.rs        # SIGINT/SIGTERM → AtomicBool RUNNING flag
└── threading.rs     # Single-threaded + parallel (barrier-synchronized) sync loops
```

---

## Hot-Path Optimizations

### 1. Inline syscalls (x86_64)

On x86_64, `pread64`, `pwrite64`, and `clock_nanosleep` are emitted as inline `syscall` instructions, bypassing libc's PLT indirection and errno handling. Each saves ~5-10 instructions.

```rust
// asm/syscall.rs — emits a single `syscall` instruction
core::arch::asm!(
    "syscall",
    inlateout("rax") 17_u64 => ret,  // SYS_pread64
    in("rdi") fd, in("rsi") buf, in("rdx") count, in("r10") offset,
    lateout("rcx") _, lateout("r11") _,
);
```

On non-x86_64 (aarch64, riscv64), these fall back to libc.

### 2. SSSE3 SIMD hex parser

The debugfs TSF file outputs `0x%016llx\n` — exactly 16 zero-padded hex digits. The SSSE3 pipeline converts all 16 digits in ~8 instructions:

```
Step 1: MOVDQU   — load 16 ASCII hex bytes
Step 2: PAND+PCMPGTB+PADDB — ASCII → nibble (0x0F mask + conditional +9 for a-f/A-F)
Step 3: PMADDUBSW [16,1,...] — pack nibble pairs → 8 bytes
Step 4: PMADDWD [256,1,...] — pack byte pairs → 4 u16 values
Step 5: PSHUFB   — gather into little-endian u64
```

Falls back to scalar for non-standard formats or non-x86_64.

### 3. Assembly verification

Automated checks verify the optimizer did its job:

```bash
nix run .#check-asm            # 7 checks: syscall present, no PLT calls, SIMD instructions
nix run .#check-asm -- --dump  # also print hot-path disassembly
```

Verified assertions:
- `syscall` instruction present in `read_tsf`, `write_tsf`, `sleep_until`, `run_single`
- No `call.*pread`, `call.*pwrite`, `call.*clock_nanosleep` (no libc PLT)
- `PMADDUBSW`, `PMADDWD`, `PSHUFB` present in hex parser context

---

## Control Algorithm

Matches FiWiTSF's algorithm exactly:

1. `raw_err = master_tsf - follower_tsf` (signed i64, microseconds)
2. If Kalman enabled: `err = kalman.update(raw_err)` (Q=50.0, R=4000.0)
3. `step = (err * kp_ppm) / 1_000_000`
4. Clamp to `+-max_step_us`
5. Force `+-1us` minimum if error is nonzero but step rounds to zero
6. Write `follower_tsf + step` back to debugfs

The Kalman filter is a 1D filter (`KalmanFilter1D`) that smooths the error signal, reducing jitter from noisy TSF reads.

---

## Threading Modes

### Single-threaded (default)

Round-robin: read master once, then iterate over all followers. Simple, deterministic, lowest overhead for small radio counts.

### Parallel (`--parallel`)

Barrier-synchronized with `std::sync::Barrier` + `AtomicU64`:

```
Sampler thread          Worker 0         Worker 1    ...  Worker N-1
      │                    │                │                │
  read master TSF          │                │                │
  store AtomicU64          │                │                │
      │ ── barrier1 ──────►│◄───────────────│◄───────────────│
      │                 read follower    read follower    read follower
      │                 apply+write     apply+write      apply+write
      │ ── barrier2 ──────►│◄───────────────│◄───────────────│
  advance deadline         │                │                │
  sleep_until              │                │                │
```

All threads inherit `SCHED_FIFO` from the parent (set before `thread::spawn`).

---

## CLI

```
tsf-sync-debugfs [OPTIONS] -m <MASTER> -f <FOLLOWER>...

Options:
  -m, --master <PATH>         Master debugfs TSF file
  -f, --follower <PATH>       Follower debugfs TSF file (repeatable)
  -c, --cpu <CPU>             Pin to CPU core
  -p, --period-ms <MS>        Sync period [default: 10]
  -P, --priority <PRI>        SCHED_FIFO priority [default: 80]
  -k, --kp-ppm <PPM>          Proportional gain [default: 1000000]
  -s, --max-step-us <US>      Max correction step [default: 200]
  -u, --stats-interval <SEC>  Print stats every N seconds [default: 0=off]
  -G, --rms-warn <US>         Warn if RMS exceeds threshold
  -K, --kalman                Enable 1D Kalman filter
  -j, --parallel              Barrier-synchronized parallel mode
```

### Example

```bash
# Discover paths
ls /sys/kernel/debug/ieee80211/phy*/netdev:wlan*/tsf

# 4 radios, 10ms period, stats every 5s
tsf-sync-debugfs \
  -m /sys/kernel/debug/ieee80211/phy0/netdev:wlan0/tsf \
  -f /sys/kernel/debug/ieee80211/phy1/netdev:wlan1/tsf \
  -f /sys/kernel/debug/ieee80211/phy2/netdev:wlan2/tsf \
  -f /sys/kernel/debug/ieee80211/phy3/netdev:wlan3/tsf \
  -p 10 -u 5
```

---

## Tests

53 unit tests across 6 modules:

| Module | Tests | What they cover |
|--------|:-----:|-----------------|
| `asm::hex` | 18 | Scalar parser (5), SIMD parser (10), auto-dispatch (3) |
| `asm::syscall` | 4 | pread64/pwrite64 round-trip, bad fd, clock_nanosleep |
| `control` | 12 | clamp_step (6), proportional controller (5), Kalman (1) |
| `debugfs` | 8 | Decimal formatting (3), TsfFile I/O via tempfile (5) |
| `rt` | 6 | advance_deadline (4), now_monotonic (2) |
| `stats` | 5 | Welford accuracy, reset, negative errors |

Run with:

```bash
cargo test --bin tsf-sync-debugfs
```

---

## Benchmarking

### Criterion microbenchmarks

```bash
nix run .#bench-hot-path
# or: cargo bench --bench hot_path
```

Benchmarks: SIMD vs scalar hex parsing, inline vs libc syscall overhead, decimal formatting.

### Head-to-head comparison (all sync modes)

```bash
nix run .#tsf-sync-benchmark-4      # 4 radios, 30s
nix run .#tsf-sync-benchmark-24     # 24 radios, 60s
nix run .#tsf-sync-benchmark-100    # 100 radios, 60s
nix run .#tsf-sync-benchmark-all    # all radio counts
```

Runs all 5 sync modes (phc2sys, kernel, io_uring, Rust debugfs, C debugfs) in a microVM with `mac80211_hwsim`, collecting `strace -c` syscall counts and `/usr/bin/time -v` resource stats.

See [Comparison: tsf-sync vs FiWiTSF](comparison.md) for detailed results.

---

## When to Use This Tool

| Use case | Recommended mode |
|----------|-----------------|
| Lab bring-up, quick testing | `tsf-sync-debugfs` (no kernel module needed) |
| Production, <60 cards | `tsf-sync start` (Mode A: phc2sys, default) |
| Production, 60-100+ cards | `tsf-sync start --sync-mode kernel` (Mode B) or `--sync-mode iouring` (Mode C) |
| Benchmarking, syscall comparison | `tsf-sync-debugfs` vs FiWiTSF head-to-head |
| No `CONFIG_MAC80211_DEBUGFS` | Must use `tsf-sync` (kernel module path) |
