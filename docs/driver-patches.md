# Upstream WiFi PTP Patches

We maintain per-driver kernel patches that add PTP hardware clock (`/dev/ptpN`) support to 6 WiFi drivers. Each patch follows the pattern Intel's `iwlwifi` already uses: a self-contained `ptp.c` + `ptp.h` within the driver directory, registering the card's TSF as a PTP clock. Once upstream, these make the out-of-tree `tsf-ptp` module unnecessary for the patched drivers.

All patches are developed against Linux v6.12 (pinned) and verified against stable and latest kernels via Nix infrastructure.

---

## Table of Contents

- [Overview](#overview)
- [ath9k — Atheros AR9xxx](#ath9k--atheros-ar9xxx)
- [ath10k — Qualcomm QCA988x/6174](#ath10k--qualcomm-qca988x6174)
- [ath11k — Qualcomm QCA6390/WCN6855](#ath11k--qualcomm-qca6390wcn6855)
- [mt76 — MediaTek MT7915/7921/7996](#mt76--mediatek-mt791579217996)
- [rtw88 — Realtek RTL8822/8723/8821](#rtw88--realtek-rtl882287238821)
- [rtw89 — Realtek RTL8852/8851](#rtw89--realtek-rtl88528851)
- [Common Design Patterns](#common-design-patterns)
- [Patch Verification](#patch-verification)
- [Nix Targets Reference](#nix-targets-reference)
- [Applying Patches Manually](#applying-patches-manually)
- [Relationship to tsf-ptp Module](#relationship-to-tsf-ptp-module)

---

## Overview

| Driver | Chipsets | TSF Access | PTP Ops | Kernel Versions |
|--------|----------|------------|---------|-----------------|
| ath9k | AR9xxx | Register (AR_TSF_L32/U32) | get/set/adj | v6.12 ✓, 6.18 ✓, 6.19 ✓ |
| ath10k | QCA988x, QCA6174, QCA9377, QCA9984 | WMI firmware | get/adj | v6.12 ✓, 6.18 ✓, 6.19 ✓ |
| ath11k | QCA6390, QCN9074, WCN6855, IPQ8074 | WMI firmware | adj only | v6.12 ✓, 6.18 ✗, 6.19 ✗ |
| mt76 | MT7915/7916/7986, MT7996, MT7921/7922/7925 | Per-chipset callbacks | get/set/adj + crosststamp | v6.12 ✓, 6.18 ✓, 6.19 ✗ |
| rtw88 | RTL8822BE/CE, RTL8723DE, RTL8821CE | Register (0x0560/0x0564) | get/set/adj | v6.12 ✓, 6.18 ✗, 6.19 ✗ |
| rtw89 | RTL8852AE/BE, RTL8851BE | Register (R_AX_TSFTR_P0) | get/set/adj | v6.12 ✓, 6.18 ✓, 6.19 ✓ |

**Access latency tiers:**
- **Register-based** (ath9k, rtw88, rtw89): 1–10 µs round-trip via MMIO
- **Per-chipset abstracted** (mt76): register for mt7915/mt7996, MCU for mt7921 — varies by chipset
- **WMI firmware** (ath10k, ath11k): 100–500 µs round-trip via firmware command queue

---

## ath9k — Atheros AR9xxx

Direct register-based TSF access via `ath9k_hw_gettsf64()` / `ath9k_hw_settsf64()`, which read/write the `AR_TSF_L32` and `AR_TSF_U32` hardware registers. Lowest latency of the Atheros drivers — no firmware involvement.

**PTP operations:**

| Op | Implementation | Notes |
|----|---------------|-------|
| `gettime64` | `ath9k_hw_gettsf64()` → register read | AR_TSF_L32 + AR_TSF_U32 |
| `settime64` | `ath9k_hw_settsf64()` → register write | Direct MMIO |
| `adjtime` | Read-modify-write via ath9k_hw functions | Atomic under `sc->mutex` |
| `adjfine` | No-op (returns 0) | Fixed crystal oscillator |

**Key details:**
- Locking: `sc->mutex` protects all TSF access
- Registration: `ath9k_ptp_init()` called from `ath9k_init_device()`, cleanup from `ath9k_deinit_device()`
- TSF µs → PTP ns: `ns = usec * NSEC_PER_USEC`

**Files changed (6 files, +153):**

```
drivers/net/wireless/ath/ath9k/Kconfig   |   1 +
drivers/net/wireless/ath/ath9k/Makefile  |   2 +
drivers/net/wireless/ath/ath9k/ath9k.h   |   6 ++
drivers/net/wireless/ath/ath9k/init.c    |   3 +
drivers/net/wireless/ath/ath9k/ptp.c     | 113 +++++++++++++  (new)
drivers/net/wireless/ath/ath9k/ptp.h     |  28 +++  (new)
```

---

## ath10k — Qualcomm QCA988x/6174

TSF access via WMI firmware commands — no direct register reads. Each TSF read requires a round-trip to firmware (`ath10k_wmi_request_stats` + `wait_for_completion_timeout`), adding ~100–500 µs latency. TSF adjustment uses the firmware's `inc_tsf`/`dec_tsf` vdev parameters, avoiding the read-modify-write path entirely.

**PTP operations:**

| Op | Implementation | Notes |
|----|---------------|-------|
| `gettime64` | WMI stats request + completion wait | 500 ms timeout |
| `settime64` | Not implemented | No WMI path for absolute set |
| `adjtime` | `WMI vdev_param inc_tsf/dec_tsf` | Direction-dependent param |
| `adjfine` | No-op (returns 0) | Fixed crystal oscillator |

**Key details:**
- Locking: `ar->conf_mutex` protects all WMI operations
- PTP clock registered when first vdev is created (`ath10k_ptp_start`), stores `ptp_vdev_id` for TSF access
- TSF read is asynchronous: WMI event handler calls `ath10k_ptp_tsf_event()` to deliver the value
- `adjtime` walks the vdev list to find the active vdev matching `ptp_vdev_id`

**Files changed (7 files, +224):**

```
drivers/net/wireless/ath/ath10k/Kconfig  |   1 +
drivers/net/wireless/ath/ath10k/Makefile |   1 +
drivers/net/wireless/ath/ath10k/core.h   |  11 ++
drivers/net/wireless/ath/ath10k/core.c   |   5 +
drivers/net/wireless/ath/ath10k/mac.c    |   5 +
drivers/net/wireless/ath/ath10k/ptp.c    | 179 +++++++++++++  (new)
drivers/net/wireless/ath/ath10k/ptp.h    |  21 +++  (new)
```

---

## ath11k — Qualcomm QCA6390/WCN6855

TSF adjustment via `WMI_VDEV_PARAM_TSF_INCREMENT`. Unlike ath10k, ath11k has no synchronous WMI path for reading TSF — `gettime64` and `settime64` return `-EOPNOTSUPP`. This limits the driver to adjustment-only operation: `phc2sys` cannot read the clock directly, but firmware-side TSF increments still work for coarse alignment.

**PTP operations:**

| Op | Implementation | Notes |
|----|---------------|-------|
| `gettime64` | Returns `-EOPNOTSUPP` | No synchronous WMI read path |
| `settime64` | Returns `-EOPNOTSUPP` | No WMI path for absolute set |
| `adjtime` | `WMI_VDEV_PARAM_TSF_INCREMENT` | ns → µs conversion |
| `adjfine` | No-op (returns 0) | Fixed crystal oscillator |

**Key details:**
- Locking: `ar->conf_mutex` protects vdev lookup and WMI calls
- PTP clock registered per-pdev (per-radio) during `ath11k_core_pdev_create`
- `adjtime` dynamically finds the first active vdev via `ath11k_ptp_find_vdev()`
- Per-radio architecture: multi-radio SoCs (IPQ8074) get one PTP clock per radio

**Files changed (6 files, +180):**

```
drivers/net/wireless/ath/ath11k/Kconfig  |   1 +
drivers/net/wireless/ath/ath11k/Makefile |   1 +
drivers/net/wireless/ath/ath11k/core.h   |  11 ++
drivers/net/wireless/ath/ath11k/core.c   |  15 ++
drivers/net/wireless/ath/ath11k/ptp.c    | 128 +++++++++++++  (new)
drivers/net/wireless/ath/ath11k/ptp.h    |  21 +++  (new)
```

---

## mt76 — MediaTek MT7915/7921/7996

Common PTP implementation at the `mt76_dev` level with per-chipset TSF access abstracted via `mt76_ptp_ops` callbacks. This handles the diversity of MediaTek's lineup: mt7915/mt7996 use direct MMIO registers (`MT_LPON_UTTR0/UTTR1`), while mt7921/mt7925 go through MCU firmware commands. The only driver that implements `getcrosststamp`, providing system-to-device clock correlation.

**PTP operations:**

| Op | Implementation | Notes |
|----|---------------|-------|
| `gettime64` | `ptp_ops->tsf_read()` | Per-chipset callback |
| `settime64` | `ptp_ops->tsf_write()` | Only if chipset provides write callback |
| `adjtime` | Read-modify-write via callbacks | Atomic under `dev->mutex` |
| `adjfine` | No-op (returns 0) | Fixed crystal oscillator |
| `getcrosststamp` | `ktime_get_raw()` + `tsf_read()` + `ktime_get_real()` | System-device correlation |

**Key details:**
- Locking: `dev->mutex` protects all TSF access
- `mt76_ptp_ops` struct: chipset drivers set `tsf_read` and optionally `tsf_write` during init
- `settime64` and `adjtime` are conditionally registered — NULL if chipset lacks write callback
- Functions exported via `EXPORT_SYMBOL_GPL` since mt76 is a multi-module driver

**Per-chipset TSF access:**

| Chipset | Method | Registers |
|---------|--------|-----------|
| MT7915/7916/7986 | Direct register | MT_LPON_UTTR0/UTTR1 |
| MT7996 | Direct register | Register-based TSF |
| MT7921/7922/7925 | MCU firmware | MCU commands |

**Files changed (4 files, +164):**

```
drivers/net/wireless/mediatek/mt76/Makefile   |   1 +
drivers/net/wireless/mediatek/mt76/mt76.h     |  17 +++
drivers/net/wireless/mediatek/mt76/mac80211.c |   4 +
drivers/net/wireless/mediatek/mt76/ptp.c      | 142 +++++++++++++  (new)
```

---

## rtw88 — Realtek RTL8822/8723/8821

Direct register-based TSF access via `rtw_read32`/`rtw_write32`. The rtw88 driver doesn't define TSF register symbols, so the patch defines them locally: `REG_TSFTR_LOW` (0x0560) and `REG_TSFTR_HIGH` (0x0564). Uses a high-low-high read sequence to guard against the low 32 bits wrapping between reads.

**PTP operations:**

| Op | Implementation | Notes |
|----|---------------|-------|
| `gettime64` | `rtw_read32(0x0560)` + `rtw_read32(0x0564)` | High-low-high sequence |
| `settime64` | `rtw_write32` to both registers | Low then high |
| `adjtime` | Read-modify-write | Atomic under `rtwdev->mutex` |
| `adjfine` | No-op (returns 0) | Fixed crystal oscillator |

**Key details:**
- Locking: `rtwdev->mutex` protects all register access
- TSF registers: 64-bit µs counter split across two 32-bit MMIO registers
- High-low-high read pattern: reads high, low, high again; if high changed (low wrapped), re-reads low
- Registration: `rtw88_ptp_init()` called from `rtw_register_hw()`, cleanup from `rtw_unregister_hw()`

**Files changed (6 files, +177):**

```
drivers/net/wireless/realtek/rtw88/Kconfig  |   1 +
drivers/net/wireless/realtek/rtw88/Makefile |   2 +
drivers/net/wireless/realtek/rtw88/main.h   |   6 +
drivers/net/wireless/realtek/rtw88/main.c   |   5 +
drivers/net/wireless/realtek/rtw88/ptp.c    | 137 +++++++++++++  (new)
drivers/net/wireless/realtek/rtw88/ptp.h    |  26 +++  (new)
```

---

## rtw89 — Realtek RTL8852/8851

Direct register-based TSF access using the AX-generation port 0 registers already defined in `reg.h`: `R_AX_TSFTR_LOW_P0` (0xC438) and `R_AX_TSFTR_HIGH_P0` (0xC43C). Same high-low-high read pattern as rtw88. Covers WiFi 6/6E hardware.

**PTP operations:**

| Op | Implementation | Notes |
|----|---------------|-------|
| `gettime64` | `rtw89_read32(R_AX_TSFTR_LOW_P0/HIGH_P0)` | High-low-high sequence |
| `settime64` | `rtw89_write32` to both registers | Low then high |
| `adjtime` | Read-modify-write | Atomic under `rtwdev->mutex` |
| `adjfine` | No-op (returns 0) | Fixed crystal oscillator |

**Key details:**
- Locking: `rtwdev->mutex` protects all register access
- Registers already defined in `reg.h` (unlike rtw88 which needs local defines)
- Port 0 (primary) TSF used for PTP clock
- Registration: `rtw89_ptp_init()` called from `rtw89_core_register()`, cleanup from `rtw89_core_unregister()`

**Files changed (6 files, +169):**

```
drivers/net/wireless/realtek/rtw89/Kconfig  |   1 +
drivers/net/wireless/realtek/rtw89/Makefile |   2 +
drivers/net/wireless/realtek/rtw89/core.c   |   3 +
drivers/net/wireless/realtek/rtw89/core.h   |   6 +
drivers/net/wireless/realtek/rtw89/ptp.c    | 140 +++++++++++++  (new)
drivers/net/wireless/realtek/rtw89/ptp.h    |  17 +++  (new)
```

---

## Common Design Patterns

All 6 patches follow the same architecture established by `iwlwifi`'s [ptp.c](https://github.com/torvalds/linux/blob/master/drivers/net/wireless/intel/iwlwifi/mvm/ptp.c):

**File structure:** Each driver gets a `ptp.c` (implementation) and `ptp.h` (declarations) within its directory. The header provides `_ptp_init()` and `_ptp_remove()` with `IS_ENABLED(CONFIG_PTP_1588_CLOCK)` stub fallbacks.

**Kconfig:** All patches add `select PTP_1588_CLOCK_OPTIONAL` to the driver's Kconfig entry. This makes PTP support available but not required — the driver builds and works without `CONFIG_PTP_1588_CLOCK`.

**Conditional compilation:** PTP code compiles only when `CONFIG_PTP_1588_CLOCK` is enabled:
```c
/* In Makefile: */
ath9k-$(CONFIG_PTP_1588_CLOCK) += ptp.o

/* In header struct: */
#if IS_ENABLED(CONFIG_PTP_1588_CLOCK)
    struct ptp_clock *ptp_clock;
    struct ptp_clock_info ptp_info;
#endif

/* In header stubs: */
#if IS_ENABLED(CONFIG_PTP_1588_CLOCK)
void ath9k_ptp_init(struct ath_softc *sc);
#else
static inline void ath9k_ptp_init(struct ath_softc *sc) {}
#endif
```

**TSF µs → PTP ns conversion:** All drivers use the same conversion since 802.11 TSF is in microseconds and PTP is in nanoseconds:
```c
/* Read:  */ *ts = ns_to_timespec64((s64)tsf * NSEC_PER_USEC);
/* Write: */ tsf = div_u64(timespec64_to_ns(ts), NSEC_PER_USEC);
/* Adj:   */ delta_usec = div_s64(delta_ns, NSEC_PER_USEC);
```

**`adjfine` is a no-op on all drivers.** WiFi cards use fixed crystal oscillators with no hardware frequency tuning. Returns 0 so tools like `phc2sys` consider the clock adjustable — actual sync happens via time-stepping (`adjtime`).

**Lifecycle:** PTP clock registered during driver init (probe/register), unregistered during remove. Registration failure is non-fatal — the driver continues without PTP support.

---

## Patch Verification

All patches are developed against a pinned Linux v6.12 source tree (fetched via `fetchFromGitHub` in `patches/kernel-source.nix`). The Nix infrastructure also tests against nixpkgs' stable and latest kernel sources to detect upstream breakage early.

### Multi-kernel results

Run the full test suite to see current results:

```bash
nix run .#patch-test-all
```

Example output (results depend on current nixpkgs kernel versions):

| Driver | v6.12 (pinned) | stable (6.18.x) | latest (6.19.x) |
|--------|:--------------:|:----------------:|:----------------:|
| ath9k | ✓ | ✓ | ✓ |
| ath10k | ✓ | ✓ | ✓ |
| ath11k | ✓ | ✗ | ✗ |
| mt76 | ✓ | ✓ | ✗ |
| rtw88 | ✓ | ✗ | ✗ |
| rtw89 | ✓ | ✓ | ✓ |

Failures against newer kernels indicate upstream driver changes that require patch updates. The pinned v6.12 source is the development target — all 6 patches always apply there.

### What the test suite checks

The `patch-test-all` script runs 4 phases:

1. **Format checks** — Signed-off-by present, `wifi: <driver>:` subject convention, SPDX headers, include guards, no trailing whitespace
2. **Apply verification** — `patch -p1 --dry-run` against pinned, stable, and latest kernel sources
3. **Conflict detection** — Sequential application of all 6 patches to a single tree to verify they don't conflict
4. **Patch statistics** — Lines added/removed per driver

---

## Nix Targets Reference

### Declarative checks (nix build)

| Target | What it does |
|--------|-------------|
| `patch-check-<driver>` | Verify patch applies to pinned v6.12 |
| `patch-check-<driver>-stable` | Verify patch applies to stable kernel |
| `patch-check-<driver>-latest` | Verify patch applies to latest kernel |
| `patch-check-all` | All 6 patches on pinned v6.12 (sequential) |
| `patch-check-all-stable` | All 6 patches on stable kernel |
| `patch-check-all-latest` | All 6 patches on latest kernel |
| `patch-kernel-<driver>` | Full kernel build with one patch applied |

Driver names: `ath9k-ptp`, `ath10k-ptp`, `ath11k-ptp`, `mt76-ptp`, `rtw88-ptp`, `rtw89-ptp`.

```bash
# Fast apply check for one driver
nix build .#patch-check-ath9k-ptp

# Check all patches against stable kernel
nix build .#patch-check-all-stable

# Full kernel build with mt76 patch (slow, cached)
nix build .#patch-kernel-mt76-ptp
```

### Interactive scripts (nix run)

| Target | What it does |
|--------|-------------|
| `patch-test-all` | Full test suite: format + apply + conflict + stats |
| `patch-verify` | Check patches apply cleanly (supports per-driver filter) |
| `patch-inspect` | Show diffstat, files changed, line counts per patch |
| `patch-test-format` | Kernel submission format checks |
| `patch-test-build` | Full kernel compile with all patches applied |

```bash
# Full test suite
nix run .#patch-test-all

# Check one driver
nix run .#patch-verify -- ath9k

# Inspect what a patch changes
nix run .#patch-inspect -- mt76

# Verbose apply check
nix run .#patch-verify -- --verbose

# Show full diff for a patch
nix run .#patch-inspect -- --full
```

---

## Applying Patches Manually

Each patch is a standard `git format-patch` output that applies with `patch -p1` or `git apply`:

```bash
cd /path/to/linux-source

# Apply one driver
patch -p1 < patches/ath9k/0001-wifi-ath9k-add-ptp-hardware-clock-for-tsf.patch

# Or with git
git apply patches/ath9k/0001-wifi-ath9k-add-ptp-hardware-clock-for-tsf.patch

# Apply all 6 drivers
for p in patches/*/0001-*.patch; do
  patch -p1 < "$p"
done
```

After applying, enable PTP support in your kernel config:

```
CONFIG_PTP_1588_CLOCK=y
```

The patches use `PTP_1588_CLOCK_OPTIONAL`, so the drivers build without this option — PTP code is simply compiled out.

---

## Relationship to tsf-ptp Module

The upstream patches and the out-of-tree `tsf-ptp` module serve the same purpose — exposing WiFi TSF as a PTP clock — but through different mechanisms:

| Aspect | tsf-ptp module | Upstream patches |
|--------|---------------|-----------------|
| Scope | ~20 SoftMAC drivers via mac80211 | 6 drivers, each patched individually |
| TSF access | `ieee80211_ops->get_tsf/set_tsf` | Driver-internal functions (registers, WMI) |
| Latency | Indirect via mac80211 abstraction | Direct — lowest possible for each driver |
| Maintenance | Out-of-tree, tracks mac80211 API | In-tree, maintained by driver subsystem |
| Deployment | `modprobe tsf_ptp` | Kernel rebuild or DKMS |

**For the 6 patched drivers, upstream patches are preferred** — they provide lower-latency TSF access, don't depend on mac80211 internal API stability, and will be maintained by the kernel community once accepted.

**`tsf-ptp` remains needed for the ~14 other supported drivers** (ath5k, ath12k, brcmsmac, b43, carl9170, wlcore, wcn36xx, p54, iwlegacy, etc.) that don't have upstream patches yet.

**Long-term goal:** all SoftMAC WiFi drivers register their own PTP clock natively, making `tsf-ptp` obsolete. The 6 patches here are the first wave.
