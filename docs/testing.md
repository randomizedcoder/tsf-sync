# Testing Strategy

---

## Test Foundation: `mac80211_hwsim`

`mac80211_hwsim` is the Linux kernel's virtual WiFi driver, purpose-built for testing. It implements `get_tsf`/`set_tsf` with a ktime-based software clock — exactly the ops our `tsf-ptp` module wraps.

### Key properties

| Property | Value |
|----------|-------|
| Module | `mac80211_hwsim` (in-tree, available on all Linux systems) |
| TSF implementation | `ktime_get_real()` + per-radio `s64 tsf_offset` |
| `get_tsf` / `set_tsf` | Yes / Yes |
| `offset_tsf` | No |
| PTP clock | No (this is what `tsf-ptp` adds) |
| Radio creation | `modprobe mac80211_hwsim radios=N` or dynamic via generic netlink |
| Driver identification | `/sys/class/ieee80211/phyN/device/driver` → `mac80211_hwsim` |
| Clock drift | None — all radios share ktime base, only offset differs |
| Debugfs TSF | Via standard mac80211 path: `/sys/kernel/debug/ieee80211/phyN/netdev:wlanN/tsf` |

### Limitation: no clock drift

hwsim radios all share `ktime_get_real()` with a static offset. There's no mechanism to simulate crystal oscillator drift between radios. This means:
- PTP convergence tests will converge trivially (all clocks tick at the same rate)
- Drift tracking and frequency discipline testing requires a custom hwsim patch or real hardware

---

## Test Scripts

### `kernel/tests/validate_hwsim_tsf.sh` — Foundation Validation

**No kernel module needed.** Validates that the mac80211_hwsim TSF path works:

- Loads hwsim with N radios
- Reads TSF via debugfs, verifies positive values
- Writes TSF, reads back, verifies round-trip
- Verifies TSF advances in real time (~100,000 µs per 100ms)
- Verifies independent TSF offsets between radios
- Confirms driver identification via sysfs
- Confirms no PTP clocks from hwsim alone

```bash
sudo ./kernel/tests/validate_hwsim_tsf.sh [radios=4]
```

### `kernel/tests/test_hwsim.sh` — Full Integration

**Requires built `tsf-ptp` module.** Tests the complete stack:

1. Load mac80211_hwsim → virtual WiFi cards
2. Load tsf-ptp → PTP clocks should appear
3. Verify PTP clock count matches radio count
4. Read PTP clock time via `phc_ctl`
5. Set PTP clock time, verify round-trip
6. Run `ptp4l` briefly, verify it stays alive
7. (TODO) Hot-plug: add/remove radios, verify PTP clocks follow

```bash
sudo ./kernel/tests/test_hwsim.sh [radios=4]
```

---

## Rust Tests

### Unit tests (`cargo test`)

| Test file | What it tests |
|-----------|--------------|
| `tests/discovery_test.rs` | Mock sysfs tree, driver identification, PTP clock mapping |
| `tests/config_gen_test.rs` | Generated `ptp4l.conf` validity, primary selection logic |

### Integration tests (`cargo test -- --ignored`)

| Test file | What it tests | Requirements |
|-----------|--------------|-------------|
| `tests/integration/hwsim_test.rs` | Full stack: discovery → config → ptp4l convergence | root, hwsim, tsf-ptp, ptp4l |

Tests in `hwsim_test.rs`:

- `test_hwsim_discovery` — Load hwsim, verify `tsf-sync discover` finds all cards
- `test_hwsim_ptp_clocks_registered` — Load hwsim + tsf-ptp, verify `/dev/ptpN` count
- `test_hwsim_ptp_clock_readwrite` — PTP clock `gettime`/`settime` round-trip
- `test_hwsim_ptp4l_convergence` — Run `ptp4l`, verify clock offsets converge
- `test_hwsim_many_radios` — 100 hwsim radios, verify 100 PTP clocks
- `test_hwsim_config_generation` — Generate config, verify structure

---

## Test Matrix

| Test type | Needs root | Needs hwsim | Needs tsf-ptp | Needs ptp4l | Needs hardware |
|-----------|:----------:|:-----------:|:-------------:|:-----------:|:--------------:|
| Unit (discovery, config) | No | No | No | No | No |
| Foundation validation | **Yes** | **Yes** | No | No | No |
| PTP clock registration | **Yes** | **Yes** | **Yes** | No | No |
| PTP clock read/write | **Yes** | **Yes** | **Yes** | No | No |
| ptp4l convergence | **Yes** | **Yes** | **Yes** | **Yes** | No |
| Real hardware validation | **Yes** | No | **Yes** | **Yes** | **Yes** |

---

## What We Can Test Today (Without Kernel Module)

1. **Foundation validation** (`validate_hwsim_tsf.sh`) — proves the TSF path works
2. **Unit tests** — discovery logic, config generation (with mock data)
3. **CLI smoke test** — `cargo run -- discover` (will report "not yet implemented" but validates CLI parsing)

---

## Debugfs Tool Tests

### Unit tests (`cargo test --bin tsf-sync-debugfs`)

53 tests across 6 modules:

| Module | Tests | What they cover |
|--------|:-----:|-----------------:|
| `asm::hex` | 18 | Scalar parser (5), SIMD parser (10), auto-dispatch (3) |
| `asm::syscall` | 4 | pread64/pwrite64 round-trip, bad fd, clock_nanosleep |
| `control` | 12 | clamp_step (6), proportional controller (5), Kalman (1) |
| `debugfs` | 8 | Decimal formatting (3), TsfFile I/O via tempfile (5) |
| `rt` | 6 | advance_deadline (4), now_monotonic (2) |
| `stats` | 5 | Welford accuracy, reset, negative errors |

---

## Assembly Verification

Automated checks verify the compiler produced the expected hot-path assembly:

```bash
nix run .#check-asm            # 7 checks
nix run .#check-asm -- --dump  # also print disassembly
```

| Check | What it verifies |
|-------|-----------------|
| `syscall` in `read_tsf` | Inline syscall, no libc PLT |
| `syscall` in `write_tsf` | Inline syscall, no libc PLT |
| `syscall` in `sleep_until` | Inline syscall, no libc PLT |
| `syscall` in `run_single` | Inlined into hot loop |
| No `call.*pread` | No libc pread PLT call |
| No `call.*pwrite` | No libc pwrite PLT call |
| PMADDUBSW/PMADDWD/PSHUFB | SSSE3 SIMD hex parser present |

These checks run on the release binary (`--release`) and use `objdump -d` with demangled symbols.

---

## Criterion Microbenchmarks

```bash
nix run .#bench-hot-path
# or: cargo bench --bench hot_path
```

Benchmarks the hot-path operations in isolation:

| Benchmark | What it measures |
|-----------|-----------------|
| SIMD hex parse | SSSE3 pipeline throughput |
| Scalar hex parse | Fallback parser throughput |
| Inline syscall overhead | pread64 via `syscall` instruction |
| Libc syscall overhead | pread64 via libc wrapper |
| Decimal formatting | `format_u64_decimal` into stack buffer |

---

## MicroVM Benchmark Harness

Head-to-head comparison of all 5 sync modes in a microVM with `mac80211_hwsim`:

```bash
nix run .#tsf-sync-benchmark-4      # 4 radios, 30s
nix run .#tsf-sync-benchmark-24     # 24 radios, 60s
nix run .#tsf-sync-benchmark-100    # 100 radios, 60s
nix run .#tsf-sync-benchmark-all    # all radio counts
```

Each run:
1. Boots a microVM with hwsim radios
2. Runs each sync mode under `strace -c` (syscall counts) and `/usr/bin/time -v` (resource stats)
3. Collects wall time, RSS, context switches, page faults, syscall counts
4. Prints side-by-side comparison table

Modes tested: phc2sys (A), kernel delayed_work (B), io_uring batch (C), Rust debugfs (D), C debugfs/FiWiTSF (E).

See [Comparison: tsf-sync vs FiWiTSF](comparison.md) for detailed results.

---

## Future Test Enhancements

### Clock drift simulation

hwsim doesn't simulate drift. Options:
- Patch hwsim to add a per-radio `s64 skew_ppb` that adjusts the TSF rate
- Use a separate kthread that periodically adjusts `tsf_offset` to simulate drift
- Skip drift testing with hwsim, rely on real hardware

### Multi-host simulation

- Run multiple hwsim instances in network namespaces
- Connect via veth pairs with `ptp4l` running in each namespace
- Verify cross-namespace TSF convergence

### Stress testing

- 100+ hwsim radios, rapid PTP clock polling
- Hot-plug: add/remove radios during active `ptp4l` sync
- Memory leak detection under sustained operation (`valgrind` on the kernel module via kmemleak)

### Property-based tests (proptest)

- TSF↔timespec64 conversion: round-trip for all u64 values
- Config generation: random card topologies → valid `ptp4l` configs
