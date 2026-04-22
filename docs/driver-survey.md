# Linux WiFi Driver Compatibility Survey

Comprehensive survey of TSF and PTP support across all mainline Linux WiFi drivers (as of kernel ~6.12). This determines which cards work natively with PTP and which need the `tsf-ptp` module.

---

## Full Driver Table

| Driver | Hardware | `get_tsf` | `set_tsf` | `offset_tsf` | PTP (native) | tsf-ptp support | Notes |
|--------|----------|:---------:|:---------:|:------------:|:------------:|:---------------:|-------|
| **iwlwifi (mvm)** | Intel AX200/201/210/211, BE200, 7260, 8265 | Yes | No | No | **Yes** | Not needed | Already exposes PTP clock via GP2. `getcrosststamp` for precise correlation. No `set_tsf` — firmware doesn't support direct TSF writes. |
| **mt76 (mt7921/mt7922)** | MediaTek MT7921, MT7922 | Yes | Yes | No | No | **Yes** | Register-based TSF (`MT_LPON_UTTR0/1`, same layout as mt7915) via shared `mt792x_get_tsf`/`mt792x_set_tsf`. |
| **mt76 (mt7925)** | MediaTek MT7925 (WiFi 6E) | Yes *(ops exist)* | Yes *(ops exist)* | No | No | **No** | The `mt792x_get_tsf`/`set_tsf` ops exist but the LPON TSF mirror (`MT_LPON_UTTR0/1`) is **not populated by firmware** on this chip — every read returns 0 even after a confirmed `MT_LPON_TCR` SW_MODE latch writeback. No MCU TSF command exists in the mt7925 firmware interface. Verified on-rig 2026-04-21; see [status.md §mt7925 TSF findings](status.md#mt7925-tsf-findings-2026-04-21). |
| **mt76 (mt7915)** | MediaTek MT7915, MT7916, MT7986 | Yes | Yes | No | No | **Yes** | Register-based TSF (`MT_LPON_UTTR0/1`). |
| **mt76 (mt7996)** | MediaTek MT7996 (WiFi 7) | Yes | Yes | No | No | **Yes** | Register-based TSF. Latest MediaTek. |
| **mt76 (mt7615)** | MediaTek MT7615, MT7622 | Yes | Yes | No | No | **Yes** | Register-based TSF. |
| **ath9k** | Atheros AR9xxx, AR5008, AR9287 | Yes | Yes | No | No | **Yes** | Direct register access (`AR_TSF_L32/U32`). Very well-tested. Low latency. Excellent candidate for upstream PTP patch. |
| **ath10k** | QCA988x, QCA6174, QCA9377, QCA9984 | Yes | Yes | No | No | **Yes** | WMI firmware commands — higher latency than register-based. |
| **ath11k** | QCA6390, QCN9074, WCN6855, IPQ8074 | Yes | Yes | No | No | **Yes** | WMI-based TSF. |
| **ath12k** | QCN9274, WCN7850 (WiFi 7) | Yes | Yes | No | No | **Yes** | WMI-based TSF. |
| **rtw88** | Realtek RTL8822BE/CE, RTL8723DE, RTL8821CE | Yes | Yes | No | No | **Yes** | Register-based (`REG_TSFTR`). |
| **rtw89** | Realtek RTL8852AE/BE, RTL8851BE (WiFi 6/6E) | Yes | Yes | No | No | **Yes** | Register-based TSF. |
| **brcmsmac** | Broadcom BCM43224, BCM43225, BCM4313 | Yes | Yes | No | No | **Yes** | SoftMAC, direct register/SHM access. |
| **b43** | Broadcom BCM43xx (legacy SoftMAC) | Yes | Yes | No | No | **Yes** | Register-based (`B43_MMIO_TSF_*`). |
| **carl9170** | Atheros AR9170 (USB) | Yes | Yes | No | No | **Yes** | TSF via USB firmware commands. |
| **iwlegacy** | Intel 3945ABG, 4965AGN | Yes | Yes | No | No | **Yes** | Direct register access. Legacy hardware. |
| **wlcore** | TI WiLink 6/7/8 | Yes | Yes | No | No | **Yes** | TSF via ACX firmware commands. |
| **wcn36xx** | Qualcomm WCN3620/3660/3680 | Yes | Yes | No | No | **Yes** | TSF via SMD firmware interface. |
| **p54** | Intersil/Conexant ISL38xx | Yes | Yes | No | No | **Yes** | Firmware-based TSF. |
| **ath5k** | Atheros AR5xxx (802.11a/b/g) | Yes | Yes | No | No | **Yes** | Direct register access. Very old. |
| **b43legacy** | Broadcom BCM4301, BCM4306 | Yes | Yes | No | No | **Yes** | Very old hardware. |
| **mac80211_hwsim** | Virtual/simulated | Yes | Yes | No | No | **Yes** | Software TSF via `ktime_get_real()`. Used for testing. |
| **rtl8xxxu** | Realtek RTL8723AU/BU, RTL8192EU (USB) | Yes | **No** | No | No | Read-only | Can read TSF but not write — read-only PTP clock. |
| **wil6210** | Qualcomm QCA6335 (802.11ad 60GHz) | Yes | **No** | No | No | Read-only | WiGig/60GHz only. Read-only. |
| **brcmfmac** | Broadcom BCM43xx FullMAC | **No** | **No** | No | No | **No** | FullMAC — firmware owns TSF entirely. Not supportable. |
| **mwifiex** | Marvell 88W8766/8897/8997 | **No** | **No** | No | No | **No** | FullMAC. Not supportable. |
| **ath6kl** | Atheros AR600x FullMAC | **No** | **No** | No | No | **No** | FullMAC. Not supportable. |
| **zd1211rw** | ZyDAS ZD1211/ZD1211B (USB) | **No** | **No** | No | No | **No** | No TSF ops implemented. Not supportable. |
| **lbtf** | Marvell 88W8388 | **No** | **No** | No | No | **No** | No TSF ops. Not supportable. |

---

## Summary

- **1 driver** has native PTP: `iwlwifi` (Intel) — works today with `ptp4l`
- **~20 drivers** have `get_tsf` + `set_tsf`: fully supportable via `tsf-ptp` module
- **2 drivers** have `get_tsf` only: read-only PTP clocks (can be synchronized *from* but not *to*)
- **5 drivers** are FullMAC or missing TSF ops: not supportable
- **No driver** implements `offset_tsf` (the callback exists since kernel 4.6, zero adoption)

---

## Key Observations

### PTP is Intel-only today

`iwlwifi` is the only upstream WiFi driver that registers a PTP hardware clock. The implementation lives in `drivers/net/wireless/intel/iwlwifi/mvm/ptp.c` and was added around kernel 5.19-6.0. It uses the GP2 timer, which runs in sync with the TSF, and supports `getcrosststamp` for precise cross-clock correlation.

No other driver has done this work, though several have the register-level access that would make it straightforward (particularly `ath9k` and `mt76`).

### `offset_tsf` is dead

The `offset_tsf` callback in `ieee80211_ops` was added in kernel 4.6 to allow glitch-free TSF adjustments. Zero drivers implement it. Our kernel module's `adjtime` implementation must fall back to `get_tsf` + `set_tsf` (read-modify-write).

### FullMAC is a hard boundary

FullMAC drivers (brcmfmac, mwifiex, ath6kl) don't use mac80211 and have no `ieee80211_ops`. Firmware owns TSF entirely with no userspace access path. These cards cannot be supported without vendor firmware changes.

### SoftMAC TSF access methods vary

| Access method | Drivers | Typical latency |
|--------------|---------|----------------|
| Direct register read/write | ath9k, ath5k, mt76 (mt7915/7996/7615), rtw88, rtw89, b43, brcmsmac, iwlegacy | ~1-10 µs |
| Firmware command (WMI/MCU) | ath10k, ath11k, ath12k, mt76 (mt7921), carl9170, p54, wlcore, wcn36xx | ~10-500 µs |

Register-based drivers will give the best PTP clock accuracy. Firmware-mediated drivers add latency that limits precision.

---

## Methodology

This survey is based on analysis of the Linux kernel source (up to ~6.12), checking each driver's `ieee80211_ops` struct for the presence of `get_tsf`, `set_tsf`, and `offset_tsf` function pointers, and searching for `ptp_clock_register` calls.
