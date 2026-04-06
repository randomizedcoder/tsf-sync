# MT7925 Rate Selection Investigation

How does the MT7925 decide which MCS rate to use for each frame? This document
records what we found by analyzing the kernel driver source and firmware binaries.

**TL;DR**: Rate selection runs entirely inside the MT7925's encrypted firmware.
The Linux driver only advertises peer capabilities; firmware autonomously picks
rates. The firmware is AES-encrypted with a key fused into the chip — we cannot
read the algorithm.

## Background

802.11ax (WiFi 6E) defines MCS 0–11 per spatial stream and bandwidth. Higher MCS
means higher throughput but requires better channel conditions. A rate selection
algorithm continuously balances throughput against reliability by choosing which
MCS to use for each frame.

In Linux, rate selection can live in two places:

1. **mac80211 (minstrel_ht)** — kernel-side, open source, used by SoftMAC drivers
   (ath9k, rtw88).
2. **Firmware** — the chip's embedded MCU runs its own algorithm. Used by FullMAC
   and hybrid drivers. The host driver just says "send this frame."

MT7925 uses firmware rate adaptation. There are zero references to minstrel
anywhere in the mt76 driver tree.

## Architecture: Driver ↔ Firmware Interface

### What the driver sends (station association)

When a peer station associates, the driver sends a single
`MCU_UNI_CMD(STA_REC_UPDATE)` (command 0x03) containing these TLVs:

| TLV | Tag | Content |
|-----|-----|---------|
| `STA_REC_BASIC` | 0x00 | Peer MAC, WLAN index |
| `STA_REC_PHY` | 0x15 | PHY type bitmask, basic rate, AMPDU params, RCPI |
| `STA_REC_HT` | 0x09 | HT capability word |
| `STA_REC_VHT` | 0x0A | VHT cap, MCS maps |
| `STA_REC_HE` | — | HE cap, MCS maps |
| `STA_REC_EHT` | 0x22 | EHT cap, MCS maps per bandwidth |
| `STA_REC_RA` | 0x01 | Legacy rate bitmap + HT rx\_mcs\_bitmask |
| `STA_REC_STATE` | 0x07 | VHT opmode, bandwidth, rx\_nss |

The driver's role is **capability advertisement**, not rate decision-making. It
tells firmware "this peer supports MCS 0–11 at 80 MHz with 2 spatial streams"
and firmware takes it from there.

Assembly point: `mt7925_mcu_sta_cmd()` in `mt7925/mcu.c:1957-2016`.

### Key structs

**`sta_rec_ra_info`** (what mt7925 actually sends for tag 0x01):
```c
// mt76_connac_mcu.h:398
struct sta_rec_ra_info {
    __le16 tag;
    __le16 len;
    __le16 legacy;           // bitmap: OFDM bits 13:6, CCK bits 3:0
    u8 rx_mcs_bitmask[10];   // HT MCS rx_mask
} __packed;
```

VHT/HE/EHT MCS maps are sent via their own dedicated TLVs, not through the RA
TLV.

**`sta_phy`** (PHY parameter block embedded in several TLVs):
```c
// mt76_connac_mcu.h:560
struct sta_phy {
    u8 type;    // CCK/OFDM/HT/VHT/HE/BE
    u8 flag;    u8 stbc;   u8 sgi;    u8 bw;
    u8 ldpc;    u8 mcs;    u8 nss;    u8 he_ltf;
};
```

### What firmware reports back

Two mechanisms:

#### 1. TX Status (TXS) — per-packet

`mt7925_mac_add_txs_skb()` in `mt7925/mac.c:894-1026` parses TXS DWORDs from
firmware. From `txs_data[0]`:

```c
// mt76_connac3_mac.h:304
#define MT_TX_RATE_STBC     BIT(14)
#define MT_TX_RATE_NSS      GENMASK(13, 10)
#define MT_TX_RATE_MODE     GENMASK(9, 6)    // CCK/OFDM/HT/VHT/HE_SU/EHT_SU/...
#define MT_TX_RATE_DCM      BIT(4)
#define MT_TX_RATE_IDX      GENMASK(5, 0)    // MCS index
```

Also from TXS: bandwidth used (`MT_TXS0_BW`), ACK success/failure
(`MT_TXS0_ACK_ERROR_MASK`), retry count.

The result is stored in `wcid->rate` (a `struct rate_info`) and exposed to
mac80211 — this is what `iw dev wlan0 station dump` shows.

#### 2. WTBL polling — periodic (GI information)

`mt7925_mac_sta_poll()` in `mt7925/mac.c:22-155` reads WTBL registers directly
because GI info is not available in TXS packets:

```c
/* We don't support reading GI info from txs packets.
 * For accurate tx status reporting and AQL improvement,
 * we need to make sure that flags match so polling GI
 * from per-sta counters directly.
 */
```

Extracts EHT GI, HE GI, and VHT/HT short GI from WTBL words 5–6.

#### 3. Rate report event (unused)

```c
// mt7925/mcu.h:11
MCU_EXT_EVENT_RATE_REPORT = 0x87
```

Defined but no handler exists. Firmware can emit proactive rate report events,
but the driver ignores them — a potential extension point.

### Rate encoding in firmware interface

```c
// mt7925/mcu.h:20
#define MT_RA_RATE_NSS       GENMASK(8, 6)
#define MT_RA_RATE_MCS       GENMASK(3, 0)
#define MT_RA_RATE_TX_MODE   GENMASK(12, 9)
#define MT_RA_RATE_DCM_EN    BIT(4)
#define MT_RA_RATE_BW        GENMASK(14, 13)
```

### Fixed-rate capabilities

| Scope | Supported? | Mechanism |
|-------|-----------|-----------|
| Per-station fixed rate | **No** | `sta_rec_ra_fixed` struct exists but mt7925 never sends it |
| BSS broadcast/multicast | Yes | `bss_rate_tlv` with `bc_fixed_rate`, `mc_fixed_rate` |
| Per-frame (mgmt/beacons) | Yes | `MT_TXD1_FIXED_RATE` + `MT_TXD6_TX_RATE` in TX descriptor |
| `iw set bitrates` | No effect | Driver has no code path to pass this to firmware |

Unlike mt7915/mt7996, the mt7925 driver does **not** implement per-station
fixed-rate override (`STA_REC_RA_UPDATE`, tag 3). Buffer sizing includes the
struct (`MT7925_STA_UPDATE_MAX_SIZE`), but no code path populates it.

## Firmware Binary Analysis

### Files examined

From `linux-firmware-20260309`:

| File | Size | Purpose |
|------|------|---------|
| `WIFI_RAM_CODE_MT7925_1_1.bin` | 1,246,968 B | Main WiFi firmware (NDS32 MCU) |
| `WIFI_MT7925_PATCH_MCU_1_1_hdr.bin` | 197,792 B | ROM patch |
| `BT_RAM_CODE_MT7925_1_1_hdr.bin` | 459,503 B | Bluetooth firmware (separate MCU) |

### Encryption verdict: AES with hardware key

All firmware payloads are **AES-encrypted** with key index 0 burned into chip
OTP/ROM. Evidence:

- **Binwalk**: zero signatures in either WiFi file — no recognizable formats
- **Entropy**: flat ~1.0 across entire payload, consistent with encryption (not
  compression)
- **Byte distribution**: 250/256 byte values in first 1024 bytes with near-uniform
  frequency — encrypted data

### Container formats

**RAM code** (trailing metadata, `struct mt76_connac2_fw_trailer`):

| Region | Load Address | Size | Flags |
|--------|-------------|------|-------|
| 0 | 0x0090d000 | 77,200 B | ENCRYPT, OVERRIDE\_ADDR (entry point) |
| 1 | 0x02212800 | 382,928 B | ENCRYPT |
| 2 | 0x00404000 | 32,720 B | ENCRYPT |
| 3 | 0xe0029400 | 584,656 B | ENCRYPT |
| 4 | 0x00000000 | 169,056 B | NON\_DL (CLC calibration, cleartext) |

Trailer: chip\_id=0x18, n\_region=5, format\_ver=0x02, build\_date=20260106153120.

**MCU patch** (leading header, `struct mt76_connac2_patch_hdr`):

- 0x00: timestamp "20260106153007a"
- 0x10: "ALPS" signature
- 0xE0+: encrypted payload

| Section | Load Address | Size | Encryption |
|---------|-------------|------|------------|
| 0 | 0x00900000 | 38,912 B | AES, key\_idx=0 |
| 1 | 0xe0002800 | 158,656 B | AES, key\_idx=0 |

### How firmware loading works

The driver acts as a **pass-through**:

1. Reads region descriptors from the firmware file
2. Checks `FW_FEATURE_SET_ENCRYPT` flag on each region
3. Sends `DL_MODE_ENCRYPT | DL_MODE_RESET_SEC_IV | DL_MODE_KEY_IDX(0)` to the
   chip's download agent via `mt76_connac_mcu_init_download()`
4. Streams encrypted bytes to the chip
5. The chip's boot ROM decrypts internally using the OTP key
6. Polls `MT_TOP_MISC2_FW_N9_RDY` for firmware readiness

The driver **never touches key material**. No AES key arrays, no cipher
operations on firmware data, no decrypt functions. The `sta_key_tlv` /
`mcu_cipher_type` code handles WiFi traffic encryption (WPA), not firmware
loading.

### Decryption feasibility

| Approach | Feasible? | Notes |
|----------|----------|-------|
| cyrozap/mediatek-wifi-re | **No** | Built for older scramble-mode (XOR) chips, not AES |
| Key in driver source | **No** | Driver never handles the key |
| Leaked SDK | Possible | MediaTek internal toolchain would have signing keys |
| JTAG/SWD debug | Possible | If debug fuses aren't blown |
| OTP glitching | Possible | Physical fault injection, requires hardware |
| Boot ROM dump | Possible | The download agent has the key in address space during early boot |

**Bottom line**: no software-only decryption path exists.

### The cleartext CLC region

Region 4 of the RAM code (169 KB) is marked `NON_DL` and is **not encrypted**.
It contains Country/Language Code calibration data parsed on the host side by
`mt7925_load_clc()`. This has regulatory parameter structures but no executable
code — not useful for understanding rate selection.

## What We Know About the Algorithm (Inference)

Although we can't read the firmware, MediaTek's rate adaptation likely follows
standard industry patterns:

- **PER-based rate down**: if packet error rate exceeds a threshold (typically
  ~20%), drop to a lower MCS
- **Probing rate up**: periodically send a frame at a higher MCS to test if
  conditions improved
- **EWMA success tracking**: exponentially weighted moving average of success
  probability per MCS index
- **Retry chain**: first attempt at target MCS, retries at successively lower MCS
- **BW/NSS fallback**: drop bandwidth (80→40→20) or spatial streams (2→1) before
  dropping MCS

We can observe these behaviors empirically:

```bash
# Current per-station TX/RX rates
iw dev wlan0 station dump

# mt76 debugfs (if available)
cat /sys/kernel/debug/ieee80211/phy0/mt76/tx_stats

# Watch rate changes under varying conditions
watch -n1 'iw dev wlan0 station dump | grep "tx bitrate"'
```

## Implications for TSF-Sync

1. **We cannot modify rate selection** — the algorithm is in encrypted firmware
   with no per-station override API in the mt7925 driver.

2. **We can observe rate decisions** — TXS reports give per-packet MCS/NSS/BW.
   Building a rate-logging tool on top of debugfs or TXS events is feasible.

3. **Rate affects timing precision** — higher MCS means shorter frame duration,
   which affects TSF measurement accuracy. Understanding rate changes helps
   interpret timing jitter.

4. **`MCU_EXT_EVENT_RATE_REPORT` (0x87)** is an unexplored extension point — if
   firmware emits these events, a driver patch could log rate adaptation decisions
   proactively rather than reconstructing them from TXS.
