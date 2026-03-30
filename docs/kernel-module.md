# Kernel Module: `tsf-ptp`

The core of the project. A small out-of-tree Linux kernel module that makes mac80211 WiFi cards visible as PTP hardware clocks.

---

## What It Does

For each WiFi phy that has `get_tsf`/`set_tsf` in its `ieee80211_ops`:

1. Register a `ptp_clock_info` with the PTP subsystem → creates `/dev/ptpN`
2. Map PTP operations to mac80211 TSF operations:

| PTP clock op | mac80211 op | Notes |
|-------------|-------------|-------|
| `gettime64` | `get_tsf` | Read TSF, convert µs → timespec64. Bracket with `ktime_get_raw_ns()` for cross-clock correlation. |
| `settime64` | `set_tsf` | Convert timespec64 → µs, write TSF. |
| `adjtime` | `get_tsf` + `set_tsf` | Read, add offset, write. (No driver implements `offset_tsf`, so we do read-modify-write.) |
| `adjfine` | Not supported | Return `-EOPNOTSUPP`. WiFi cards don't have tunable oscillators. PTP will fall back to periodic `settime64`/`adjtime`. |
| `getcrosststamp` | `get_tsf` + `ktime_get_raw_ns()` | Bracket TSF read with system timestamps for `PTP_SYS_OFFSET_PRECISE`. |

---

## Module Design

```c
// Pseudocode — actual implementation in C

struct tsf_ptp_card {
    struct ptp_clock_info   ptp_info;
    struct ptp_clock       *ptp_clock;
    struct ieee80211_hw    *hw;
    struct ieee80211_vif   *vif;
};

// Called for each phy at module load (or hot-plug)
static int tsf_ptp_probe(struct ieee80211_hw *hw)
{
    if (!hw->ops->get_tsf)
        return -ENOTSUP;

    struct tsf_ptp_card *card = kzalloc(...);
    card->ptp_info = (struct ptp_clock_info) {
        .owner       = THIS_MODULE,
        .name        = "tsf-ptp",
        .max_adj     = 0,           // no frequency adjustment
        .gettime64   = tsf_ptp_gettime,
        .settime64   = tsf_ptp_settime,
        .adjtime     = tsf_ptp_adjtime,
        .getcrosststamp = tsf_ptp_getcrosststamp,
    };
    card->ptp_clock = ptp_clock_register(&card->ptp_info, ...);
    ...
}

static int tsf_ptp_gettime(struct ptp_clock_info *info, struct timespec64 *ts)
{
    struct tsf_ptp_card *card = container_of(info, ...);
    u64 tsf_usec = drv_get_tsf(card->hw, card->vif);
    *ts = ns_to_timespec64(tsf_usec * 1000);  // µs → ns → timespec64
    return 0;
}
```

---

## Key Challenges

### 1. mac80211 locking

`get_tsf`/`set_tsf` are called under `ieee80211_local->mtx` in the debugfs path. Our module needs to acquire the same lock, or use the `drv_get_tsf()` wrapper which handles locking. The `drv_get_tsf()` / `drv_set_tsf()` helpers in `net/mac80211/driver-ops.h` are the correct entry points — they handle locking, tracing, and driver state checks.

### 2. VIF requirement

Most `get_tsf`/`set_tsf` implementations require a `vif` (virtual interface). The card must have an active interface (e.g., `wlan0` up) for TSF ops to work. The module needs to:
- Track VIF creation/destruction via mac80211 callbacks or notifiers
- Return `-ENODEV` from PTP ops when no VIF exists
- Re-enable PTP clock functionality when a VIF becomes available

### 3. Hot-plug

Cards can appear and disappear (PCIe reset, USB disconnect). The module must:
- Register a notifier for phy add/remove events
- Call `ptp_clock_unregister()` cleanly on removal
- Handle the race between PTP clock use and card removal

### 4. No `adjfine`/`adjfreq`

WiFi cards don't have tunable crystal oscillators. PTP's frequency discipline won't work — it must fall back to periodic time-stepping (`adjtime` or `settime64`). This means slightly coarser sync than a NIC with hardware frequency adjustment, but still well within our needs (µs, not ns).

### 5. TSF unit conversion

TSF is in microseconds (u64). PTP clocks use `timespec64` (seconds + nanoseconds). Conversion:
- `gettime64`: `ns_to_timespec64(tsf_usec * NSEC_PER_USEC)`
- `settime64`: `div_u64(timespec64_to_ns(ts), NSEC_PER_USEC)`

Edge case: TSF near `u64::MAX` (~584,942 years in µs) won't overflow in practice.

### 6. Discovering mac80211 hardware

The module needs to find all ieee80211_hw instances. Options:
- **Iterate at load time:** Walk the list of registered ieee80211 hardware via internal mac80211 data structures.
- **Notifier chain:** Register for `IEEE80211_DEV_READY` / `IEEE80211_DEV_GOING_DOWN` notifications (if available).
- **sysfs/debugfs approach:** Walk `/sys/class/ieee80211/` from a workqueue at init.

This is the most architecturally complex part of the module — mac80211 doesn't have a clean "enumerate all hw" API for external modules.

---

## Deployment

### NixOS

Build as part of the kernel module set:
```nix
boot.extraModulePackages = [ tsf-ptp-module ];
```

The `nix/kernel-module.nix` file handles building against the running kernel's headers.

### DKMS (non-NixOS)

```bash
cp -r kernel/ /usr/src/tsf-ptp-0.1.0/
dkms add tsf-ptp/0.1.0
dkms build tsf-ptp/0.1.0
dkms install tsf-ptp/0.1.0
```

### Manual

```bash
cd kernel/
make KDIR=/lib/modules/$(uname -r)/build
sudo insmod tsf_ptp.ko
```

### Upstream aspiration

Long-term, the goal is per-driver PTP patches upstream — the same approach iwlwifi took. The `tsf-ptp` module serves as a stopgap and proof of concept. Priority targets for upstream patches:
- `mt76` — actively maintained, large user base
- `ath9k` — excellent register-level TSF access, well-understood hardware
- `ath11k`/`ath12k` — modern Qualcomm, active development
