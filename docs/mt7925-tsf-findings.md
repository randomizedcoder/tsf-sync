# MT7925 TSF Investigation

> **Status:** confirmed dead hardware path, **both directions**. Read via
> `mt792x_get_tsf` returns 0 (LPON UTTR mirror never populated); write via
> `mt792x_set_tsf` lands in registers but does not reach the on-chip TSF
> counter that stamps beacon bodies (empirically verified on 2026-04-22).
> See §[Verdict](#verdict) and §[Critical open question: does `set_tsf`
> work?](#critical-open-question-does-set_tsf-work).
>
> **Last updated:** 2026-04-22

This document captures the full investigation into why TSF synchronisation does
not work on MediaTek MT7925 WiFi 6E cards, even though the mt76 driver appears
to expose the same `get_tsf`/`set_tsf` ops as its mt7921/mt7922 siblings.

It covers:
- What we tried in the upstream-style patch series (0001–0005).
- The full kernel code path a TSF read traverses, and the exact point where it
  fails on mt7925.
- How the independent FiWiTSF project attacks the same problem, and why it
  fails for the same reason.
- The one genuinely new idea in FiWiTSF — affine TSF mapping — and what it
  changes (and doesn't change) for us.
- Alternative TSF sample sources that bypass the broken read path.
- **The critical open question:** can we still `set_tsf` on mt7925? If not, no
  approach to hardware-level TSF coordination is possible on this chip.

---

## Table of contents

- [Goal and original plan](#goal-and-original-plan)
- [What we built: the patch series](#what-we-built-the-patch-series)
- [The kernel code path a TSF read traverses](#the-kernel-code-path-a-tsf-read-traverses)
- [What we observed on the rig](#what-we-observed-on-the-rig)
- [Three theories, one verdict](#three-theories-one-verdict)
- [How FiWiTSF attacks the same problem](#how-fiwitsf-attacks-the-same-problem)
- [The one new idea from FiWiTSF: affine mapping](#the-one-new-idea-from-fiwitsf-affine-mapping)
- [Alternative TSF sample sources](#alternative-tsf-sample-sources)
- [Critical open question: does `set_tsf` work?](#critical-open-question-does-set_tsf-work)
- [Options going forward](#options-going-forward)

---

## Goal and original plan

We want to synchronise the 802.11 TSF (Timing Synchronisation Function)
counters across co-located MT7925 radios on a single host so that beacon
scheduling, EDCA slot boundaries, and power-save windows align across APs —
reducing uncoordinated beaconing and co-channel interference. The project's
chosen transport is the Linux PTP clock API (`/dev/ptpN`), mirroring what
Intel's `iwlwifi` already does natively for AX210. See
[architecture.md](architecture.md) for the full design rationale.

For mt76, the plan was a small patch series that exposes TSF through the PTP
clock API by wrapping each driver's existing `ieee80211_ops->get_tsf` /
`set_tsf` callbacks. These callbacks already exist in-tree for mt7921, mt7922
and mt7925 — they reach TSF via direct MMIO to `MT_LPON_UTTR0/UTTR1` paired
with an `MT_LPON_TCR` software-read/write handshake, shared through
`mt792x_get_tsf()` / `mt792x_set_tsf()` in `mt792x_core.c`. The same pattern
works on mt7915 in-tree, so the assumption was that extending it to the
`mt792x` family would be mechanical.

---

## What we built: the patch series

Five patches land in
`patches/net-next/mt76/`. All are applied to the l2 NixOS host via
`boot.kernelPatches`; the kernel on l2 is 6.19.11.

| Patch | Purpose | Status on mt7925 |
|---|---|---|
| **0001** — `wifi-mt76-add-ptp-hardware-clock-for-tsf.patch` | Generic PTP clock infrastructure at the `mt76_dev` level. Registers one `/dev/ptpN` per `mt76_dev` when a chipset driver supplies an `mt76_ptp_ops` table. Gated on `CONFIG_PTP_1588_CLOCK`. | Applies, compiles, no effect until a chipset wires it up. |
| **0002 / 0003** — test patches | KUnit + kselftest for the PTP conversion and clock ops. | Pass under `mac80211_hwsim`. |
| **0004** (revised 2026-04-21) — `wifi-mt76-register-ptp-ops-for-mt792x.patch` | Registers `mt76_ptp_ops` for mt7921 and mt7922 only. **mt7925 was originally included and has been explicitly dropped** after on-rig measurements. | mt7925 intentionally excluded. |
| **0005** — `wifi-mt76-add-mt7925-tsf-probe-debugfs.patch` | Diagnostic debugfs file at `/sys/kernel/debug/ieee80211/phyN/mt76/tsf_probe`. For every active vif it prints the result of the canonical `mt792x_get_tsf()` call plus raw `MT_LPON_TCR` / `MT_LPON_UTTR0` / `MT_LPON_UTTR1` readback values. | Kept in-tree as a living reproducer. |

Both 0004 (revised) and 0005 are merged to `main` in
[randomizedcoder/tsf-sync#7](https://github.com/randomizedcoder/tsf-sync/pull/7)
and [#8](https://github.com/randomizedcoder/tsf-sync/pull/8).

---

## The kernel code path a TSF read traverses

Every userspace surface we have considered ultimately funnels into the same
in-kernel function. Understanding this is the key to understanding why
workarounds in the userspace layer can't help.

### From userspace into mac80211

There are four places userspace can ask for a TSF on an mt76 card:

| Surface | Userspace call | Kernel entry |
|---|---|---|
| PTP clock (tsf-sync default) | `clock_gettime(/dev/ptpN, &ts)` | `ptp_clock_info.gettime64` → `mt76_ptp_gettime64` (this series, patch 0001) |
| tsf-sync-debugfs (Mode D) | `pread(".../tsf")` | `ieee80211_if_fmt_tsf` in `net/mac80211/debugfs_netdev.c` |
| FiWiTSF `tsf_sync_rt_starter` | `read(".../tsf")` | Same as above |
| nl80211 vendor cmd (option C) | — | Not implemented for TSF on any driver |

All three of the working surfaces converge on the same inner call:

```
userspace
  └─ → debugfs "tsf" file  OR  /dev/ptpN clock_gettime
        └─ → mac80211: drv_get_tsf(local, sdata)             ← net/mac80211/driver-ops.h
              └─ → local->ops->get_tsf(hw, vif)              ← ieee80211_ops indirect call
                    └─ → mt7921_ops / mt7922_ops .get_tsf = mt792x_get_tsf
                          └─ → (see next section)
```

The debugfs path is
`ieee80211_if_fmt_tsf()` → `drv_get_tsf(local, sdata)` → the driver op.
The PTP path is our `mt76_ptp_gettime64` → `ptp_ops->tsf_read(mdev)` →
`mt792x_ptp_tsf_read()`, which is structurally identical to `mt792x_get_tsf`
(hardcodes `HW_BSSID_0` instead of picking via `omac_idx`, but reads the same
registers).

**Every existing userspace surface ends at `mt792x_get_tsf()` or its PTP
twin.** This is why none of the sync-mode alternatives (A phc2sys, B kernel
worker, C io_uring, D debugfs) in `docs/options-considered.md` helps: they are
all loop-placement choices on top of the same read.

### Inside `mt792x_get_tsf()`

Source: `drivers/net/wireless/mediatek/mt76/mt792x_core.c`.

```c
u64 mt792x_get_tsf(struct ieee80211_hw *hw, struct ieee80211_vif *vif)
{
    struct mt792x_dev *dev = mt792x_hw_dev(hw);
    struct mt792x_vif *mvif = (struct mt792x_vif *)vif->drv_priv;
    u8 omac_idx = mvif->bss_conf.mt76.omac_idx;
    u16 n = omac_idx > HW_BSSID_MAX ? HW_BSSID_0 : omac_idx;
    union { u64 t64; u32 t32[2]; } tsf;

    mt792x_mutex_acquire(dev);

    mt76_set(dev, MT_LPON_TCR(0, n), MT_LPON_TCR_SW_MODE);  // (1) latch
    tsf.t32[0] = mt76_rr(dev, MT_LPON_UTTR0(0));            // (2) read low
    tsf.t32[1] = mt76_rr(dev, MT_LPON_UTTR1(0));            // (3) read high

    mt792x_mutex_release(dev);
    return tsf.t64;
}
```

The hardware contract the code assumes:

1. Writing `MT_LPON_TCR_SW_MODE` (bit 0 of `MT_LPON_TCR(0, n)`) tells the LPON
   block to freeze the TSF mirror at the current moment.
2. `MT_LPON_UTTR0(0)` then holds the low 32 bits of that frozen snapshot.
3. `MT_LPON_UTTR1(0)` holds the high 32 bits.

On mt7915 and mt7921/7922, this contract is honoured. On mt7925 it is not.

### What we actually see on mt7925

The `tsf_probe` debugfs (patch 0005) reads all three registers around the
`mt792x_get_tsf` call. On every card, every vif, every poll:

```
vif <mac> type=3 omac_idx=0 n=0
  mt792x_get_tsf()   = 0x0000000000000000   (decimal 0)
  MT_LPON_TCR before = 0x01640006
  MT_LPON_TCR after  = 0x01640007   ← SW_MODE bit set, readback confirms the write landed
  MT_LPON_UTTR0      = 0x00000000
  MT_LPON_UTTR1      = 0x00000000
```

The TCR latch write reaches the register (readback shows the SW_MODE bit is
set). The UTTR registers read zero regardless. No amount of retrying, waiting,
or restarting changes the result. Four cards in the rig, all behave
identically.

---

## What we observed on the rig

Verified 2026-04-21 on host `l2` (4 × MediaTek MT7925 PCIe cards, kernel
6.19.11 with patches 0001 + 0004-including-mt7925 + 0005 applied):

- `/dev/ptp0` .. `/dev/ptp3` registered as expected.
- `clock_gettime(/dev/ptpN, …)` returned `0` every time on every card.
- `cat /sys/kernel/debug/ieee80211/phyN/mt76/tsf_probe` reproduced the failure
  with raw register dumps (see numbers above).
- The same mt792x code path works on mt7921/mt7922 silicon per upstream
  testing. Offsets, locking, code path — all identical.
- mt7925 firmware does **not** expose a `TWT_AGRT_GET_TSF` MCU command; that
  helper exists only in mt7996/mt7915 firmware interfaces.

---

## Three theories, one verdict

| Theory | Claim | Test | Verdict |
|---|---|---|---|
| **A** | `MT_LPON_TCR` SW_MODE latch writes don't reach the hardware | TCR readback after the write | **Ruled out** — readback is `0x01640007` on every card; the write lands. |
| **B** | The LPON TSF mirror is not populated by mt7925 hardware or firmware | `MT_LPON_UTTR0/UTTR1` readback after a confirmed TCR latch | **Confirmed** — both registers read 0 on every vif, every card, every time. |
| **C** | Register offsets are wrong for mt7925 | Cross-check against in-tree `mt792x_get_tsf` used by mt7921/7922 | **Ruled out** — identical offsets, known to work on that silicon. |

### Verdict

The LPON TSF mirror path (`MT_LPON_TCR` + `MT_LPON_UTTR0/UTTR1`) is dead
silicon on mt7925. There is no MCU replacement in the firmware interface.
Patch 0004 was subsequently revised to exclude mt7925; patch 0005 remains
in-tree as a diagnostic that will immediately reveal a future firmware fix
(the moment `UTTR0`/`UTTR1` start returning non-zero, the whole tsf-sync stack
starts working on this chip).

---

## How FiWiTSF attacks the same problem

[FiWiTSF](https://git.umbernetworks.com/rjmcmahon/FiWiTSF) is an independent
project with the same goal (TSF sync across co-located radios on one host).
Its two binaries have very different relevance:

### `tsf_sync_rt_starter` — same dead path, different skin

Source: `tsf_sync_rt_starter.c` in the FiWiTSF repo. A C11 real-time daemon
that reads a master radio's debugfs `tsf` file and nudges followers via their
debugfs `tsf` files.

```c
static int read_tsf_hex(const char *path, uint64_t *out)
{
    ...
    fd = open(path, O_RDONLY);                              // path = /sys/kernel/debug/.../tsf
    ...
    n = read(fd, buf, sizeof(buf) - 1);
    ...
    if (sscanf(buf, "0x%llx", (unsigned long long *)out) != 1)
        goto out;
    ...
}
```

This reaches `ieee80211_if_fmt_tsf()` → `drv_get_tsf()` → `mt792x_get_tsf()` —
the same dead LPON read we already traced. **FiWiTSF's primary sync binary
fails on mt7925 for exactly the same reason our stack does.**

This is the project's own Mode D / options-considered Option A, just
reimplemented in C with `SCHED_FIFO` + Welford statistics + an optional 1D
Kalman filter. Nothing in the read path is materially different.

### `tsf_affine` — a genuinely new idea

The second piece of FiWiTSF (`tsf_affine.c`, `tsf_affine.h`, and the design
note in `TEAM_EMAIL_affine_tsf_mapping.txt`) is architecturally different and
worth discussing on its own. See next section.

---

## The one new idea from FiWiTSF: affine mapping

### What it is

Instead of stepping every radio's hardware TSF to match a master, keep each
radio **free-running** and maintain a software **affine map** per radio that
predicts its TSF from the master's:

```
t_radio_i ≈ α_i · t_master + β_i
```

Paired samples `(t_master, t_radio_i)` feed a sliding-window least-squares
fit. With 24 radios and one master, you maintain 23 maps (the master is the
identity). `tsf_affine.c:17-61` is the whole fit; it's just
covariance-over-variance for α and offset-of-means for β, with anchor
subtraction to keep everything in `int64`.

Software that needs to schedule something at a particular master-TSF instant
calls `tsf_affine_pool_master_to_radio()`, which returns the predicted
per-radio TSF via
`predict_radio()` (`tsf_affine.c:97-107`).

### Why this is interesting

It decouples two things our options matrix implicitly coupled:

| Concern | In PTP-based design | In affine design |
|---|---|---|
| **Sample source** — where TSF values come from | `drv_get_tsf` | Anything that produces `(master, radio)` pairs |
| **Correction** — how we act on offsets | `drv_set_tsf` (threshold-gated) | None — software prediction replaces hardware stepping |

For a **measurement / scheduling** workload (e.g. "I want to know the current
TSF on radio 7, or trigger an event at a specific master-TSF instant"), affine
mapping needs no `set_tsf` at all.

For an **on-air-alignment** workload (e.g. EDCA slot boundaries, coordinated
beacon transmission across co-located APs), it still doesn't help — slot
boundaries are MAC-layer events driven by the chip's own internal TSF. A
software map can predict them, but cannot move them.

The FiWiTSF design note calls this out explicitly:

> Caveats: This gives a unified **software** timebase. Features that truly
> require hardware TSF alignment to the master (specific offload, certain MAC
> behaviors) still need separate consideration.

### Why it still doesn't save us on mt7925 by itself

`tsf_affine_pool_sample(pool, i, master_tsf, radio_tsf)` needs the
`master_tsf` and `radio_tsf` values from somewhere. FiWiTSF gets them from
`read_tsf_hex()` — i.e. debugfs — i.e. `mt792x_get_tsf()` — i.e. the dead path.

**On mt7925, FiWiTSF's affine layer, if fed through its own standard sample
path, receives a stream of zeros.** The affine math is fine; the input is
wrong.

What the affine layer changes is the *shape of the problem*: it becomes
useful the moment we can feed it paired samples from any source other than
`drv_get_tsf`. See the next section.

---

## Alternative TSF sample sources

The chip almost certainly still maintains an internal TSF — it has to, to
schedule its own beacon TX and to honour received-beacon BSS synchronisation.
The LPON read path happens to be unpopulated, but other on-chip paths expose
TSF values that never flow through `drv_get_tsf`. These are the candidates we
haven't yet exercised:

| Candidate | Where the TSF comes from | Can it feed an affine map? | Known-unknowns |
|---|---|---|---|
| **RX-descriptor timestamp** | Hardware stamps every received frame's RX descriptor with a 64-bit TSF at the moment of reception. Flows through the driver's RX ISR, not through `ieee80211_ops->get_tsf`. A passive monitor vif on card B observing card A's beacon yields `(B_rx_tsf, A_beacon_tsf_from_frame_body)` — one paired sample. | **Yes, directly.** | Whether the RX-desc timestamp comes from the same internal counter as the LPON mirror, or a different one, is unknown on mt7925. If the LPON mirror is the primary and the RX path reads it too, this fails. If the RX path reads a live internal counter directly, this works. Reading the driver RX path source in mt76 should answer it. |
| **TX-status descriptor timestamp** | Hardware reports the TSF at which a frame was actually transmitted, via TX status. Flows through `mt7925_mac_add_txs` and siblings, not through `get_tsf`. | **Yes**, with caveat that we're timestamping our own transmissions, so we only sample our own clock, not peers'. Combine with RX-desc for peer samples. | Same as above — is it the same internal counter as LPON? |
| **Beacon TX pre-program snapshot** | Driver programs the beacon TSF field before TX; software knows the value. | Weak — that's a software-computed value, not a hardware sample. Good as a sanity check, not as primary data. | — |
| **Undocumented register bank** | MediaTek downstream SDK (Android / OpenWrt `mt7925e` vendor tree) might read TSF from a different MMIO window — `MT_WTBL_*`, `MT_TMAC_*`, `MT_WF_*`. | Yes if one exists. | Requires a focused reverse-engineering pass on the vendor tree, then a `tsf_probe` extension that sweeps candidate offsets. |
| **MCU firmware TSF command** | Future firmware `GET_TSF` / `SET_TSF` analogous to mt7996's `TWT_AGRT_GET_TSF`. | Yes if it exists. | External dependency on MediaTek. |

The first two (RX descriptor, TX status) are the most promising because they
are pure software changes in the mt76 RX/TX path, require no firmware
cooperation, and deliberately bypass the known-broken MMIO register.

---

## Critical open question: does `set_tsf` work?

The whole investigation so far has exercised only the **read** side. We have
not tested the write side in isolation. This distinction is decisive:

- **If `set_tsf` on mt7925 works** (the write reaches the on-chip TSF and
  actually moves beacon/contention timing): then hardware-level TSF alignment
  is still achievable on this chip, we just need a different *read* source to
  drive the correction loop (any of the alternatives in the previous section).
  The EDCA use case is still live.

- **If `set_tsf` does not work** (the write lands in registers but is ignored
  by the hardware / firmware, same failure mode as `get_tsf`): then no
  approach we have considered can produce hardware TSF alignment on mt7925.
  The only remaining options are (a) software-only affine mapping for
  scheduling purposes — no on-air coordination, no EDCA slot alignment, or
  (b) swap the hardware out.

**This is the single most important experiment to run next.** It is
cheap, bounded, and determines whether the chip is partially usable or
entirely so.

### How to test it

Extend the `tsf_probe` debugfs file (or add a sibling `tsf_probe_write`)
with a one-shot write test. The test should:

1. Capture a reference TSF from a co-located, working radio (Intel AX210 on
   the same host has native PTP — use it as an external ground truth).
2. Compute a known delta that would move the mt7925's TSF by (say) 1 000 000
   µs relative to its current beacon schedule.
3. Call `mt792x_set_tsf()` with that target value. This internally writes
   `MT_LPON_UTTR0/1` then latches via `MT_LPON_TCR_SW_WRITE`.
4. Observe the effect **on-air** using an off-rig sniffer (a laptop in
   monitor mode on the same channel, capturing 500ms of beacons) or
   **in-host** via another card's RX-descriptor timestamps on those beacons.

Pre-write and post-write beacon captures give three possible outcomes:

| Observation | Interpretation |
|---|---|
| Beacon TSF field jumps by the expected delta | `set_tsf` works. The chip has a partial hardware path: writable but not readable via LPON. EDCA alignment feasible via blind writes driven by external TSF reference. |
| Beacon TSF field does not change | `set_tsf` is also dead. No hardware TSF alignment possible on mt7925. Move to affine-only or new hardware. |
| Beacon TSF field changes unpredictably or the radio drops offline | Write path corrupts state. Needs deeper investigation before relying on it. |

The test is safe: a TSF write to an AP radio will cause an immediate beacon
timing discontinuity visible to associated clients, but clients recover on
the next beacon interval. Running it on an idle test AP with no real clients
is trivially low-risk.

### What the test does not require

- No vendor firmware changes.
- No reverse engineering of the downstream tree.
- No new driver paths — `mt792x_set_tsf` already exists and is on our code
  path; we're just exercising it deliberately with an external ground truth.
- No new patches — a small extension of 0005's `tsf_probe` debugfs is
  sufficient.

### Verdict (2026-04-22): `set_tsf` is also dead silicon

Test executed on the l2 rig with patch 0006's `tsf_set` debugfs knob and a
cross-card beacon capture (wls1 on phy0 as the target AP, phy1 converted to
a dedicated monitor vif on the same channel — mt7925 is half-duplex and does
not loop its own TX beacons to a co-resident monitor vif on the same phy,
so the observer must be a sibling radio). Commands and script that produced
the verdict are reproducible via `sudo nix run .#mt7925-tsf-test` from this
repo, with the rig configured via the companion change to
`l2/hostapd-multi.nix` putting wls1 and wls2 co-channel on ch36.

**Empirical data — beacon-body TSF field (`wlan.fixed.timestamp`) captured
from wls1 BSSID 0c:cd:b4:38:73:01 via mon1 on phy1:**

```
=== BEFORE ===
t=0.063  tsf=297,984,064
t=0.165  tsf=298,086,462
t=0.267  tsf=298,188,863

=== WRITE 99,999,999,999,999 to /sys/kernel/debug/ieee80211/phy0/mt76/tsf_set ===
(write OK, no driver error)

=== AFTER ===
t=0.063  tsf=298,700,877
t=0.165  tsf=298,803,273
t=0.267  tsf=298,905,673

=== tsf_probe (post-write) ===
vif 0c:cd:b4:38:73:01 type=3 omac_idx=0 n=0
  get_tsf        = 0x0000000000000000 (0)
  TCR before     = 0x01640007
  TCR after      = 0x01640007
  UTTR0 (post)   = 0x00000000
  UTTR1 (post)   = 0x00000000
```

**Interpretation.** The AFTER beacons continue the natural progression of
the BEFORE sequence (+~102,400 µs per beacon interval, +~512 ms total
elapsed between captures). If the `MT_LPON_UTTR0/1` write + `MT_LPON_TCR`
SW_WRITE latch had reached the hardware TSF counter that stamps beacons,
the first AFTER value would be ≈ 99,999,999,999,999 + (~100 ms beacon
interval) ≈ 100,000,000,100,000. It is instead 298,700,877 — indistinguishable
from "no write happened". Simultaneously, `tsf_probe` confirms UTTR0/UTTR1
still read 0 post-write, meaning firmware does not populate the register
mirror in either direction.

This matches the "Beacon TSF field does not change" row in the test matrix
above. **No approach using `mt792x_set_tsf` + beacon-body TSF can produce
hardware TSF alignment on mt7925.** The only remaining categories are
alternative on-chip TSF sample sources (RX-descriptor timestamps, TX-status
timestamps) feeding a software-only affine-mapping layer — which is useful
for scheduling against an external reference but does not give on-air EDCA
slot alignment across mt7925 radios.

---

## Options going forward

Given all of the above, three sequenced questions drive the next phase of
work:

1. ~~**Does `set_tsf` work on mt7925?**~~ **Answered 2026-04-22: no.** See
   §[Verdict (2026-04-22)](#verdict-2026-04-22-set_tsf-is-also-dead-silicon).
   Skip to step 4.

2. **What's the best alternative read source?** RX-descriptor beacon
   timestamps are the front-runner. Reading the mt76 RX path for mt7925 and
   confirming the RX descriptor carries a live hardware TSF (not derived from
   the LPON mirror) is the next small experiment. If yes, build a driver hook
   + userspace integration.

3. **Integrate the FiWiTSF affine layer.** Regardless of whether we keep
   stepping TSFs in hardware, the affine approach gives us robust software
   prediction and is already written. Easier to pull in after (2) is
   answered, because the sample source determines the integration shape.

4. **Fallback if `set_tsf` is also dead:** the mt7925 hardware is not
   suitable for on-air TSF coordination on this project's goals. Either
   (a) pivot to mt7921/mt7922 silicon (same driver family, known-working
   register path) or (b) treat mt7925 as a software-only participant
   coordinated via affine mapping against an Intel AX210 master, accepting
   that EDCA slot alignment is not achievable on mt7925 cards.

5. **Independently, in parallel with all of the above:** file an RFC /
   firmware request with MediaTek asking for an MCU `GET_TSF` / `SET_TSF`
   command analogous to mt7996's `TWT_AGRT_GET_TSF`. Zero effort on our side,
   only helps if it lands, but the clock on firmware release cycles starts
   whenever we file it.

---

## Appendix: files and references

- Patches: `patches/net-next/mt76/0001-0005-*.patch` in this repo.
- Diagnostic debugfs: `/sys/kernel/debug/ieee80211/phyN/mt76/tsf_probe` (on a
  host with patch 0005 applied). Output format documented in
  `mt7925/debugfs.c` `mt7925_tsf_probe_iter()`.
- Upstream mt76 driver source: `drivers/net/wireless/mediatek/mt76/` — in
  particular `mt792x_core.c` (shared TSF helpers) and `mt7925/init.c` (where
  `mt76_ptp_ops` would be wired).
- FiWiTSF: https://git.umbernetworks.com/rjmcmahon/FiWiTSF
  - `tsf_sync_rt_starter.c` — hits the same dead path via debugfs.
  - `tsf_affine.c` / `.h` — software affine TSF mapping (reusable).
  - `TEAM_EMAIL_affine_tsf_mapping.txt` — design note.
- Project options & design: [options-considered.md](options-considered.md),
  [architecture.md](architecture.md), [status.md](status.md).
