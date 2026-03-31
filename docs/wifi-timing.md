# WiFi Timing Requirements

## Why synchronize WiFi TSF?

tsf-sync targets deployments where a single Linux host runs multiple WiFi NICs in AP (access point) mode. These co-located APs share the same RF environment, and synchronizing their TSF (Timing Synchronization Function) clocks provides three benefits:

1. **Seamless roaming** — WiFi clients derive timing from the AP's beacons. When a client roams between APs on the same host, a synchronized TSF avoids a timing discontinuity, reducing roam latency.

2. **Coordinated beacons and contention** — 802.11 channel access is timing-driven: beacons, backoff slots, DIFS/SIFS intervals. Synchronized APs align their contention windows and beacon transmissions, reducing same-channel or overlapping-channel collisions between co-located APs.

3. **Reduced client-to-client interference** — Clients associated with different APs share the RF environment. Coordinated AP scheduling reduces scenarios where clients on different APs unknowingly contend and cause retransmissions.

---

## 802.11 MAC timing fundamentals

### TSF

The Timing Synchronization Function is a 64-bit microsecond counter maintained by every 802.11 station. It is transmitted in every beacon and probe response frame. In an infrastructure BSS, the AP is the timing master — clients synchronize their TSF to the AP's beacons.

- Resolution: 1 µs
- Width: 64 bits (wraps after ~584,942 years)
- Transmitted in: Beacon, Probe Response, ATIM frames

### Key timing parameters

| Parameter | OFDM (802.11a/g/n/ac/ax) | DSSS (802.11b) |
|-----------|--------------------------|----------------|
| Slot time | 9 µs | 20 µs |
| SIFS | 16 µs | 10 µs |
| DIFS (SIFS + 2 × slot) | 34 µs | 50 µs |
| Beacon interval | 100 TU = 102.4 ms | 100 TU = 102.4 ms |
| CW_min | 15 slots | 31 slots |
| Max first-attempt backoff | 15 × 9 µs = 135 µs | 31 × 20 µs = 620 µs |

One TU (Time Unit) = 1024 µs.

### Beacon → TX cycle

```
 Beacon    DIFS     Backoff       DATA        SIFS     ACK
 ─────── ──────── ─────────── ────────────── ─────── ────────
 |  B   | 34 µs  | 0–135 µs  |   payload   | 16 µs |  ACK  |
 ───────────────────────────────────────────────────────────────
                  ↑ random [0, CW_min] slots
```

After each beacon, stations wait DIFS then a random backoff (0 to CW_min slots) before transmitting. If two APs' TSFs are aligned within one slot time, their contention windows overlap — they participate in the same contention epoch rather than operating on offset schedules.

---

## Required sync accuracy

The accuracy requirement depends on the coordination goal:

| Goal | Required accuracy | Rationale |
|------|-------------------|-----------|
| Beacon alignment | < 1 ms (sub-TU) | Beacons are 102.4 ms apart; sub-ms keeps them visually aligned |
| Contention coordination | < 9 µs (one slot time) | APs share the same contention epoch |
| Roaming continuity | < 1024 µs (one TU) | Client TSF doesn't jump significantly on handover |

**Recommended target: ≤ 10 µs.** This keeps APs within one OFDM slot time, providing contention coordination — the most demanding requirement. It is achievable for drivers with register-based TSF access.

---

## Sources of TSF access latency

The latency of `get_tsf` / `set_tsf` calls varies by driver architecture:

| Driver type | Examples | Typical latency | Mechanism |
|-------------|----------|-----------------|-----------|
| Register-based (MMIO) | ath9k, rtw88, rtw89 | 1–10 µs | Direct register read/write |
| Firmware command | ath10k, ath11k, ath12k, mt76 (MCU) | 10–500 µs | Async firmware command round-trip |
| Native PTP (GP2) | iwlwifi | < 1 µs | Hardware PTP clock (exposes GP2, not raw TSF) |

See [Driver Survey](driver-survey.md) for per-driver details.

---

## Impact of set_tsf on firmware

On real hardware (unlike `mac80211_hwsim`), frequent `set_tsf` calls can have side effects:

- **TX pause** — Some firmware implementations briefly pause TX/RX during a TSF update to maintain internal consistency.
- **Command contention** — The `set_tsf` firmware command competes with time-critical beacon and data paths for the firmware command queue.
- **Unnecessary work** — When clocks are already synchronized within TSF resolution (1 µs), most `set_tsf` calls produce zero observable change.

This motivates **threshold-based filtering**: skip `set_tsf` when the offset is below a configurable threshold. The `adjtime_threshold_ns` module parameter controls this. The threshold is tunable at load time and at runtime via sysfs — no recompilation needed.

### Tuning the threshold

The threshold controls the trade-off between sync accuracy and firmware interaction. The right value depends on your hardware and how sensitive it is to frequent `set_tsf` calls. All values below are well within the 9 µs OFDM slot time, so contention coordination is maintained at every level.

| Value | Accuracy | Firmware load | When to use |
|-------|----------|---------------|-------------|
| **1000 ns (1 µs)** | Maximum — matches TSF resolution | Highest — most offsets exceed 1 µs, so most calls pass through | You need the tightest possible sync (e.g., research, measurement setups) and your hardware handles frequent `set_tsf` without issues. Aggressive — start here only if you know your firmware tolerates it. |
| **5000 ns (5 µs)** *(default)* | High — well within half a slot time | Moderate — filters the majority of sub-slot corrections once clocks converge | Good starting point for most deployments. Provides strong contention coordination while significantly reducing firmware interaction compared to 1 µs. |
| **10000 ns (10 µs)** | Acceptable — right at the one-slot-time boundary | Lowest — nearly all steady-state corrections are filtered | Appropriate for firmware-sensitive hardware where `set_tsf` is known to cause TX pauses. Should be validated with radio-level analysis (e.g., beacon capture, air-time utilization monitoring) to confirm that contention coordination is not degraded at this threshold. |

**Choosing a value:**
- Start at **5000 ns** and monitor the counters (below). If `adjtime_apply_count` is climbing at or near the phc2sys poll rate (10 Hz default) after convergence, the threshold may be too low for your hardware's drift — consider raising it.
- If you observe contention issues in packet captures despite sync being "active", the threshold may be too high — lower it.
- The threshold can be changed at runtime without reloading the module: `echo 3000 > /sys/module/tsf_ptp/parameters/adjtime_threshold_ns`

### Monitoring adjtime counters

The kernel module exposes two counters for observing sync behavior:

```bash
cat /sys/module/tsf_ptp/parameters/adjtime_skip_count    # offsets below threshold (skipped)
cat /sys/module/tsf_ptp/parameters/adjtime_apply_count   # offsets above threshold (set_tsf called)
```

**What to look for:**

- **Healthy sync** — After initial convergence (first few seconds), `adjtime_skip_count` should climb steadily while `adjtime_apply_count` plateaus. A high skip-to-apply ratio (e.g., 10:1 or better) means clocks are staying in sync and the threshold is doing its job — unnecessary firmware calls are being avoided.

- **Bad clock / high drift** — If `adjtime_apply_count` keeps climbing at a rate close to the phc2sys poll rate (default 10 Hz), the NIC's clock is drifting faster than the threshold can absorb. This may indicate a poor oscillator or a driver that resets TSF unexpectedly. Consider investigating the hardware, or if the sync accuracy is still acceptable, raising the threshold.

- **Threshold too high** — If `adjtime_skip_count` is very high but you observe poor beacon alignment (e.g., via packet captures), the threshold may be filtering out corrections that matter. Lower it.

- **Threshold too low** — If `adjtime_apply_count` is high but offsets are consistently sub-µs (visible in phc2sys log output), the threshold isn't filtering effectively. Raise it to reduce firmware interaction.

The daemon also logs both counters at each health-check interval, so these values appear in the journal without manual polling.

---

## Standards references

- IEEE 802.11-2020 (IEEE Std 802.11-2020):
  - §9.2.5 — TSF synchronization (TSF definition, beacon timing)
  - §10.3.2.3 — Slot time
  - §10.3.2.4 — Interframe space (SIFS/DIFS values)
  - §10.23 — DCF (contention window, backoff procedure)
  - §11.1.3.1 — TSF timer (64-bit µs counter specification)
  - §11.11 — Radio measurement (AP coordination, BSS transition; originally IEEE 802.11k-2008)
- Wi-Fi Alliance WMM specification (EDCA timing parameters)
- [DCF Interframe Space](https://en.wikipedia.org/wiki/DCF_Interframe_Space) — accessible overview
- [IEEE 802.11 Working Group](https://www.ieee802.org/11/) — standards home page
