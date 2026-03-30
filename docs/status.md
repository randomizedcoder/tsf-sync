# Project Status

> Last updated: 2026-03-29

---

## Current Phase: Phase 1 — Single Host

### Completed

- [x] **Design exploration** — evaluated 5 TSF access methods, 4 distribution architectures, 14 Linux IPC primitives
- [x] **Architecture decision** — PTP-based approach selected over custom sync daemon ([rationale](architecture.md))
- [x] **Driver survey** — 27 Linux WiFi drivers audited for TSF/PTP support ([full table](driver-survey.md))
- [x] **Design documents** — architecture, kernel module, userspace tool, topology, testing, error handling
- [x] **Rust project scaffolding** — compiles, CLI with subcommands, NixOS flake with crane
- [x] **Kernel module skeleton** — `tsf_ptp.c` with PTP clock op stubs, Makefile, DKMS config
- [x] **Test infrastructure** — `validate_hwsim_tsf.sh` (foundation), `test_hwsim.sh` (integration), Rust test stubs
- [x] **NixOS packaging** — flake, dev shell, CI checks, service module
- [x] **Implement discovery** — `tsf-sync discover` walks sysfs, identifies cards, detects PTP clocks and driver types
- [x] **Implement config generation** — `tsf-sync config` produces valid `ptp4l.conf` with auto/manual primary selection
- [x] **Module loader** — `/proc/modules` parsing, modprobe/insmod/rmmod with fallback logic
- [x] **ptp4l process management** — start/stop/restart with SIGTERM→SIGKILL, stdout/stderr log forwarding
- [x] **Health monitoring** — pmc-based health query, port state parsing, health state classification
- [x] **Start/stop commands** — `tsf-sync start` and `tsf-sync stop` orchestrate full stack lifecycle
- [x] **Status command** — `tsf-sync status` queries ptp4l and displays clock health table
- [x] **Daemon mode** — full lifecycle with signal handling, ptp4l crash restart, periodic health logging
- [x] **Discovery unit tests** — mock sysfs tests: Intel native PTP, MediaTek, FullMAC, missing driver, read-only, mixed topology, many radios (7 integration + 12 unit tests)
- [x] **Config generation unit tests** — primary selection, auto-prefer-Intel, error cases, comment generation (7 integration + 9 unit tests)
- [x] **Module loader unit tests** — /proc/modules parsing, hyphen/underscore normalization (5 tests)
- [x] **Health monitoring tests** — pmc output parsing, offset classification, display formatting (4 tests)
- [x] **Kernel module implementation** — full PTP clock ops with mac80211 internal API usage
  - [x] PTP clock registration via `ptp_clock_register()` per phy
  - [x] mac80211 hw discovery via `class_for_each_device` on ieee80211 class
  - [x] `gettime64` → `drv_get_tsf()` with spinlock protection
  - [x] `settime64` → `drv_set_tsf()` with spinlock protection
  - [x] `adjtime` → read-modify-write with spinlock protection
  - [x] `adjfine` → returns `-EOPNOTSUPP` (no tunable oscillators)
  - [x] `getcrosststamp` → bracketed TSF read with `ktime_get_raw()`/`ktime_get_real()`
  - [x] VIF lifecycle tracking via netdevice notifier (NETDEV_UP/DOWN/UNREGISTER)
  - [x] Existing VIF scan at module load time
  - [x] Read-only PTP clocks for drivers with `get_tsf` but no `set_tsf`
  - [x] Clean module exit with PTP clock unregistration
- [x] **Integration test implementations** — hwsim_test.rs with 6 tests (discovery, PTP registration, read/write, ptp4l convergence, 100-radio stress, config generation)

### Not Yet Verified (requires root + kernel headers)

- [ ] **Validate foundation** — run `sudo kernel/tests/validate_hwsim_tsf.sh` (needs root)
- [ ] **Build kernel module** — `make` in `kernel/` (needs kernel 6.19.9 dev headers)
- [ ] **Run integration test** — `sudo kernel/tests/test_hwsim.sh` (needs built module + root)
- [ ] **Run Rust integration tests** — `sudo cargo test --test hwsim_test -- --ignored` (needs root + modules)

- [x] **Hot-plug support** — NETDEV_REGISTER probes new wiphys, NETDEV_UNREGISTER removes PTP clocks when wiphy goes away
- [x] **Deployment guide** — complete `docs/deployment.md` with NixOS, DKMS, manual install, configuration, verification, troubleshooting
- [x] **NixOS kernel module build** — `nix/kernel-module.nix` for building tsf-ptp against current kernel, wired into NixOS module

### Next Steps

- [ ] **Validate foundation** — run `sudo kernel/tests/validate_hwsim_tsf.sh` (needs root)
- [ ] **Build kernel module for running kernel** — needs 6.19.9 headers
- [ ] **Run integration tests** — `sudo kernel/tests/test_hwsim.sh` and `sudo cargo test --test hwsim_test -- --ignored`
- [ ] **Real hardware test** — Intel AX210 (native PTP) + MediaTek MT7925 (tsf-ptp module)

---

## Test Summary

| Test Suite | Tests | Status |
|------------|-------|--------|
| `discovery` (unit) | 12 | All passing |
| `discovery` (integration) | 7 | All passing |
| `config_gen` (unit) | 7 | All passing |
| `config_gen` (integration) | 9 | All passing |
| `module_loader` (unit) | 5 | All passing |
| `health` (unit) | 4 | All passing |
| `ptp4l` (unit) | 2 | All passing |
| `daemon` (unit) | 2 | All passing |
| `hwsim` (integration) | 6 | Written, needs root |
| **Total** | **54** | **48 passing, 6 need root** |

---

## Phase 2 — Multi-Host

Not started. Depends on Phase 1 completion.

- [ ] PTP over Ethernet between hosts (ptp4l configuration only — no code changes)
- [ ] `tsf-sync` generates multi-host-aware configs
- [ ] Cross-host TSF convergence validation
- [ ] Network requirements documentation (switch config, MLD snooping)
- [ ] GPS / atomic clock integration via `ts2phc`
- [ ] Fill in `docs/multi-host.md`

---

## Phase 3 — Upstream

Not started. Depends on Phase 1 being stable.

- [ ] Prepare per-driver PTP patch (start with mt76 or ath9k)
- [ ] Engage with kernel maintainers
- [ ] Submit to linux-wireless@vger.kernel.org
- [ ] Iterate on review feedback
- [ ] Fill in `docs/upstream.md`

---

## Key Decisions Made

| Decision | Chosen | Over | Why |
|----------|--------|------|-----|
| TSF access | PTP clock (kernel module) | debugfs, eBPF, nl80211 | Stable ABI, integrates with PTP ecosystem, works for ~20 drivers |
| Sync protocol | PTP (IEEE 1588) via `ptp4l` | Custom daemon, SeqLock+futex, tokio | Don't reinvent clock sync. Multi-host for free. Datacenter-proven. |
| Distribution | `ptp4l` handles it | Shared memory, channels, multicast | PTP eliminates the need for custom distribution |
| Testing | mac80211_hwsim | Real hardware only | Virtual driver with `get_tsf`/`set_tsf`, no hardware needed, CI-friendly |

---

## Known Risks

| Risk | Severity | Mitigation | Status |
|------|----------|-----------|--------|
| mac80211 API changes between kernel versions | Medium | DKMS, target LTS, upstream patches (Phase 3) | Accepted |
| No frequency discipline for WiFi cards | Low | Time-stepping is fine for µs accuracy | Accepted |
| ptp4l untested with 100 clocks | Medium | Test early, may need multiple instances | **Needs validation** |
| Intel PTP exposes GP2, not raw TSF | Medium | Validate with beacon captures | **Needs validation** |
| VIF required for TSF ops | Low | Document requirement, return -ENODEV | **Implemented** |
| mac80211 internal headers required | Medium | Build against full kernel source, version-specific | Accepted |
