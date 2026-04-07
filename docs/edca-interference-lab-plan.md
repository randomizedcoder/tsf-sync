# Dense WiFi EDCA & Lab Testing Plan

## 1. Introduction: Twenty Radios, One Roof, One Problem

Picture a single Linux host with twenty MT7925 PCIe NICs, each running hostapd,
each serving five to ten clients. A hundred devices sharing the same air. From a
distance, each AP looks healthy — associated clients, flowing traffic, reasonable
signal strength. But the aggregate numbers tell a different story: retransmission
rates climbing past 20%, throughput plateauing well below what the radios can
deliver, and latency spikes that make real-time applications stutter.

The root cause is not interference in the traditional sense. These APs are not on
different channels stepping on each other. The problem is subtler: when multiple
BSSes share a channel, their contention clocks are uncoordinated. Each AP's TSF
(Timing Synchronization Function) counter drifts independently. Slot boundaries —
the discrete time units that 802.11's contention algorithm relies on — fall at
different moments for different APs. The result is collisions that the protocol's
self-correction mechanism cannot see, and therefore cannot fix.

This document explains why that happens, how TSF synchronization addresses it,
how to tune hostapd's EDCA parameters for dense deployments, and how to measure
the impact on real hardware through a rigorous lab testing plan.

Before diving in, you should be familiar with the timing fundamentals in
[`wifi-timing.md`](wifi-timing.md) (especially the parameter table at lines 27-34
and the sync target discussion at line 62) and the system architecture in
[`architecture.md`](architecture.md).

---

## 2. How 802.11 Decides When to Transmit

### 2.1 Listen Before Talk

WiFi operates on an unlicensed shared medium. Unlike wired Ethernet, a station
cannot detect collisions while transmitting — the power of its own signal drowns
out everything else. So 802.11 uses a **listen-before-talk** scheme: before
transmitting, a station senses the medium and only proceeds if the channel has
been idle long enough.

The original mechanism, DCF (Distributed Coordination Function), defined a simple
rule: wait for DIFS, then pick a random backoff, count it down while the medium
stays idle, and transmit. EDCA (Enhanced Distributed Channel Access), introduced
in 802.11e and mandatory since 802.11n, extends DCF with four access categories
(ACs) that provide differentiated priority. Every modern WiFi device uses EDCA.

The fundamental timeline for two stations contending looks like this:

```
Station A:  ... medium busy ... | AIFS | backoff=3 | backoff=2 | backoff=1 | TX →
Station B:  ... medium busy ... | AIFS | backoff=5 | backoff=4 | backoff=3 | ...
                                                                             ↑
                                                          A wins, B freezes counter at 3
```

Station A drew a smaller backoff and transmits first. Station B freezes its
countdown at 3, waits for A's transmission and ACK to finish, waits another AIFS,
then resumes counting down from 3. This is a cooperative, probabilistic system —
it works well when everyone agrees on the same time reference.

### 2.2 DIFS, AIFS, and the Interframe Hierarchy

802.11 defines a hierarchy of interframe spaces that enforce priority:

- **SIFS** (Short Interframe Space): 16 µs for OFDM PHYs. Used for ACKs,
  CTS responses, and other high-priority control frames. No station performing
  normal channel access can begin transmitting this soon after the medium goes
  idle, so SIFS-triggered frames always win.

- **DIFS** (DCF Interframe Space): SIFS + 2 × slot_time = 16 + 2 × 9 = **34 µs**.
  The minimum wait before a DCF/EDCA station can begin its backoff countdown.

- **AIFS** (Arbitration Interframe Space): A per-AC generalization of DIFS.
  Each access category has its own AIFSN (Arbitration Interframe Space Number):

  ```
  AIFS[AC] = SIFS + AIFSN[AC] × slot_time
  ```

  For OFDM PHYs (slot_time = 9 µs, SIFS = 16 µs):

  | AC    | AIFSN | AIFS (µs) |
  |-------|-------|-----------|
  | AC_VO |   2   |    34     |
  | AC_VI |   2   |    34     |
  | AC_BE |   3   |    43     |
  | AC_BK |   7   |    79     |

  AC_VO and AC_VI begin their backoff countdown 34 µs after the medium goes idle.
  AC_BE must wait an additional 9 µs (one slot), and AC_BK waits five extra slots
  beyond that. This means a best-effort frame cannot even start counting down
  until a voice or video frame in the same contention round has already consumed
  one slot of its backoff.

See [`wifi-timing.md`](wifi-timing.md) lines 27-34 for the complete timing
parameter table, and lines 40-46 for the beacon-to-transmission cycle diagram.

### 2.3 The Backoff Procedure in Detail

When a station has a frame to transmit, the full EDCA backoff procedure is:

1. **Sense the medium.** If it is busy, wait until it becomes idle.
2. **Wait AIFS[AC].** The medium must be idle for the full AIFS duration
   of the frame's access category.
3. **Draw a random backoff.** Select a uniform random integer from
   `[0, CW]`, where CW is the current contention window for this AC.
   Multiply by slot_time (9 µs) to get the backoff duration.
4. **Count down.** Decrement the backoff counter by one slot for each
   slot_time (9 µs) interval that the medium remains idle.
5. **Freeze on busy.** If the medium becomes busy during countdown,
   freeze the counter at its current value. When the medium goes idle
   again, wait another AIFS[AC], then resume counting down from the
   frozen value.
6. **Transmit at zero.** When the counter reaches zero, transmit the frame.
7. **Wait for ACK.** Expect a SIFS-spaced ACK from the receiver.
8. **On success:** Reset CW to CWmin for this AC.
9. **On failure** (no ACK): Double the contention window:

   ```
   CW_new = min(2 × (CW + 1) - 1, CWmax)
   ```

   This produces the sequence (for AC_BE): 15 → 31 → 63 → 127 → 255 → 511 → 1023.
   Each doubling spreads contending stations across twice as many slots,
   reducing collision probability at the cost of higher average delay.

The CW doubling is the protocol's self-correction mechanism. It works — but only
when the protocol can **detect** collisions. A missing ACK signals a collision.
But if stations on different APs are using misaligned slot boundaries, collisions
happen in ways that look like noise rather than contention, and CW doubling does
not trigger appropriately. This is where TSF sync matters.

### 2.4 EDCA: Four Lanes on the Same Road

EDCA defines four access categories, each with its own contention parameters.
The defaults below are from IEEE 802.11-2020 Table 9-155 (OFDM PHY, aCWmin=15):

| AC    | Priority | CWmin | CWmax | AIFSN | TXOP limit | Use case       |
|-------|----------|-------|-------|-------|------------|----------------|
| AC_VO | Highest  |   3   |    7  |   2   | 1.504 ms   | Voice, VoIP    |
| AC_VI | High     |   7   |   15  |   2   | 3.008 ms   | Video, streams |
| AC_BE | Normal   |  15   | 1023  |   3   | 0 (no limit)| Best effort   |
| AC_BK | Low      |  15   | 1023  |   7   | 0 (no limit)| Background     |

Why does AC_VO almost always win? Three compounding advantages:

1. **Smaller CW range.** AC_VO draws from [0, 3] — only 4 possible slots.
   AC_BE draws from [0, 15] — 16 possible slots. A voice frame's maximum
   initial backoff is 3 × 9 = 27 µs; best-effort's is 135 µs.

2. **Shorter AIFS.** AC_VO starts counting down after 34 µs. AC_BE waits
   43 µs. By the time AC_BE begins its countdown, AC_VO has already
   consumed one slot.

3. **TXOP.** Once AC_VO wins the medium, it can transmit for up to 1.504 ms
   without releasing — enough for multiple voice frames back-to-back.

In hostapd.conf, these are configured with log₂ encoding for CW values:

```
# CW value = 2^parameter - 1
# e.g., wmm_ac_be_cwmin=4 → CWmin = 2^4 - 1 = 15
wmm_ac_be_cwmin=4       # CWmin = 15
wmm_ac_be_cwmax=10      # CWmax = 1023
wmm_ac_be_aifs=3
wmm_ac_be_txop_limit=0
```

### 2.5 How This Plays Out With Many Stations

With 20 clients sharing a channel, all using AC_BE (CWmin=15), each draws from
16 possible slots. By the pigeonhole principle, collisions are frequent:

```
Slots:   [0] [1] [2] [3] [4] [5] [6] [7] [8] [9] [10] [11] [12] [13] [14] [15]
Clients:  C   A   -   B   A   C   -   D   B   -    E    -    C    A    -    B
          D               E
```

Multiple clients landing on the same slot means a collision. None receives an ACK.
All double their CW to 31 and retry. The system self-regulates — after a few
rounds of doubling, CW is large enough that collisions become rare. But this
self-regulation wastes airtime. At CW=1023, the average backoff is
511.5 × 9 µs = 4.6 ms, compared to 67.5 µs at CW=15. Frames sit in the queue
while their station counts down through hundreds of empty slots.

The lesson: contention is manageable when the protocol's feedback loop works.
The question is what happens when APs have different TSF references and that
feedback loop breaks. Section 3 quantifies this.

---

## 2B. Beacon Frames: The Heartbeat of the BSS

Every AP periodically broadcasts a beacon frame — typically every 100 TU
(102.4 ms). Beacons announce the network's existence, carry timing information,
and deliver power-save scheduling to clients. The beacon's TSF timestamp field
is the field that tsf-sync aligns across APs.

### 2B.1 Beacon Frame Structure (Byte-Level)

**MAC Header (24 bytes):**

```
Offset  Field                   Size     Value / Range
──────  ─────────────────────   ──────   ─────────────────────────────
0x00    Frame Control           2 bytes  0x8000 (Type=Mgmt, Subtype=Beacon)
          - Protocol Version              0 (always)
          - Type                          00 (Management)
          - Subtype                       1000 (Beacon)
          - To DS / From DS               0 / 0
          - More Frag / Retry / ...       0
0x02    Duration/ID             2 bytes  0x0000 (beacons set duration=0)
0x04    Destination Address     6 bytes  ff:ff:ff:ff:ff:ff (broadcast)
0x0A    Source Address (SA)     6 bytes  AP's MAC address
0x10    BSSID                   6 bytes  AP's BSSID (usually same as SA)
0x16    Sequence Control        2 bytes  Fragment=0, Sequence=0-4095
```

**Beacon Body — Fixed Fields (12 bytes):**

```
Offset  Field                   Size     Value / Range
──────  ─────────────────────   ──────   ─────────────────────────────
0x18    Timestamp (TSF)         8 bytes  64-bit µs counter (0 to 2^64-1)
0x20    Beacon Interval         2 bytes  In TU (1 TU = 1024 µs)
                                         Range: 1-65535 TU
                                         Default: 100 TU (102.4 ms)
                                         Dense deploy: 100-200 TU
                                         Power-save opt: 200-300 TU
0x22    Capability Information  2 bytes  Bitmask:
          - Bit 0: ESS (1 for AP)
          - Bit 1: IBSS (0 for AP)
          - Bit 4: Privacy (1 if encryption enabled)
          - Bit 5: Short Preamble
          - Bit 9: Short Slot Time (1 for OFDM)
          - Bit 10: Spectrum Mgmt (1 for 5/6 GHz)
```

**The TSF timestamp field (8 bytes at offset 0x18) is the field that tsf-sync
aligns across APs.** When a client receives a beacon, it adopts the AP's TSF
value as its own, ensuring all stations in a BSS share the same time reference.
When tsf-sync aligns TSF across multiple APs, all BSSes on the host share a
common time reference.

**Roaming and TSF discontinuity.** When a client roams from AP1 to AP2, it adopts
AP2's TSF from the first beacon (or reassociation response) it receives. In
standard operation, each AP's TSF drifts independently — AP2's TSF might be
milliseconds or even seconds ahead of or behind AP1's. The client's internal
timer jumps discontinuously at the moment of adoption. This jump has two
consequences: (1) the client's slot boundary reference shifts, meaning its
in-progress backoff countdown is now misaligned with the new BSS's contention
epoch, and (2) any power-save scheduling based on TBTT (e.g., when to wake for
the next DTIM beacon) must be recalculated from the new TSF.

With tsf-sync, all APs share the same TSF to within ≤ 10 µs. A roaming client
adopts a TSF value that is nearly identical to what it already had — no
discontinuity, no slot boundary shift, no TBTT recalculation. The client's
contention state carries over cleanly to the new BSS. This is particularly
valuable for 802.11r (Fast BSS Transition), where the goal is to minimize roam
disruption: eliminating the TSF jump removes one source of post-roam transient
contention.

### 2B.2 Information Elements (Variable-Length TLVs)

After the fixed fields, beacons carry a chain of Information Elements (IEs).
Each IE has the format: `Tag (1 byte) | Length (1 byte) | Value (Length bytes)`.

Key IEs and their acceptable value ranges:

| IE ID | Name | Length | Acceptable Values | Notes |
|-------|------|--------|-------------------|-------|
| 0 | SSID | 0-32 | UTF-8 string or empty | 0-length = hidden SSID |
| 1 | Supported Rates | 1-8 | Rate×2 Mbps (e.g., 0x8C = 6M mandatory) | Bit 7 = mandatory |
| 3 | DS Parameter Set | 1 | Channel number (1-14, 36-165, 1-233) | Band-dependent |
| 5 | TIM | 4-254 | See §2B.3 | DTIM count, period, bitmap |
| 7 | Country | ≥3 | Country code + regulatory triplets | "US", "DE", power limits |
| 32 | Power Constraint | 1 | 0-255 dBm reduction from regulatory max | Per 802.11h |
| 42 | ERP Information | 1 | Bit 0: NonERP present, Bit 1: Use protection | 2.4 GHz only |
| 45 | HT Capabilities | 26 | Channel width, SGI, MCS set, A-MPDU | WiFi 4+ |
| 48 | RSN (WPA2/3) | 2-255 | Cipher/AKM suites, PMF capabilities | Required WPA2/WPA3 |
| 50 | Extended Supported Rates | 1-255 | Additional rate entries | When >8 rates |
| 61 | HT Operation | 22 | Primary channel, secondary offset, width | 40 MHz control |
| 127 | Extended Capabilities | 1-15 | Bitmask of extended features | BSS transition, etc. |
| 191 | VHT Capabilities | 12 | Max MPDU, BW support, MCS per NSS | WiFi 5+ |
| 192 | VHT Operation | 5 | Channel width (0-3), center freq segments | 80/160 MHz |
| 255 (ext 35) | HE Capabilities | variable | HE MAC/PHY caps, MCS-NSS set | WiFi 6 |
| 255 (ext 36) | HE Operation | variable | BSS color, PE duration, MCS | WiFi 6 |
| 255 (ext 108) | EHT Capabilities | variable | EHT MCS, NSS, 320 MHz | WiFi 7 |
| 255 (ext 106) | EHT Operation | variable | Channel width, MCS, disabled subch | WiFi 7 |

### 2B.3 TIM and DTIM: Power-Save Scheduling

The TIM (Traffic Indication Map) IE controls when power-saving clients wake up:

```
TIM IE (ID=5):
  DTIM Count      (1 byte)  Counts down from DTIM Period-1 to 0
  DTIM Period     (1 byte)  Beacons between DTIMs (1-255, default: 2)
  Bitmap Control  (1 byte)  Bit 0 = buffered broadcast/multicast
                            Bits 1-7 = bitmap offset
  Partial Virtual Bitmap    (1-251 bytes)  Per-AID buffered unicast bits
```

The DTIM (Delivery Traffic Indication Message) mechanism:

- When DTIM Count = 0, this beacon **is** a DTIM beacon. The AP delivers buffered
  broadcast and multicast traffic immediately after the beacon.
- Power-saving clients wake for every DTIM beacon to receive multicast traffic.
- Between DTIMs, a client only wakes if its AID (Association ID) bit is set in
  the TIM bitmap, indicating buffered unicast frames.

Parameter ranges and trade-offs for dense deployments:

| Parameter | Range | Default | Dense (50-100 clients) | Rationale |
|-----------|-------|---------|------------------------|-----------|
| `beacon_int` | 15-65535 TU | 100 TU | 100-200 TU | Larger = less beacon overhead, slower client sync |
| `dtim_period` | 1-255 | 2 | 1-3 | 1 = every beacon is DTIM (responsive), 3 = save airtime |

### 2B.4 Beacon Interval Field: The TSF-Sync Connection

The Beacon Interval field (2 bytes at offset 0x20) tells clients when to expect
the next beacon. The AP schedules beacons at **TBTT** (Target Beacon Transmission
Time), defined as:

```
TBTT occurs when: TSF mod (beacon_int × 1024) == 0
```

When TSF is synchronized across APs, TBTT aligns. If co-channel APs have the same
`beacon_int`, their beacons arrive at the same instant — and collide. Two
strategies to handle this:

**Staggering:** With N co-channel APs and `beacon_int = 100 TU`, offset each AP's
TSF by `k × (100/N) × 1024 µs` for k = 0, 1, ..., N-1. For 4 co-channel APs:
stagger by 25 TU (25,600 µs), so beacons arrive 25.6 ms apart instead of
simultaneously.

Staggering is a **tsf-sync feature**, not a hostapd configuration. hostapd has no
"beacon offset" parameter — it schedules beacons at TBTT, which is derived
directly from the interface's TSF. So the way to stagger beacons is to make
tsf-sync set each co-channel AP's TSF to a different target:

```
AP0 (primary):  TSF_target = TSF_primary
AP1:            TSF_target = TSF_primary + 1 × (beacon_int / N) × 1024 µs
AP2:            TSF_target = TSF_primary + 2 × (beacon_int / N) × 1024 µs
AP3:            TSF_target = TSF_primary + 3 × (beacon_int / N) × 1024 µs
```

For `beacon_int = 100 TU` and N = 4 co-channel APs, the offsets are 0, 25,600,
51,200, and 76,800 µs. Each AP's TBTT then falls at a different quarter of the
beacon interval:

```
Time →  0 ms          25.6 ms        51.2 ms        76.8 ms        102.4 ms
        │              │              │              │              │
  AP0:  ├── beacon ──  ·              ·              ·              ├── beacon
  AP1:  ·              ├── beacon ──  ·              ·              ·
  AP2:  ·              ·              ├── beacon ──  ·              ·
  AP3:  ·              ·              ·              ├── beacon ──  ·
```

This requires tsf-sync to be **channel-aware**: it needs to know which APs share
a channel so it can group them and assign per-group offsets. APs on different
non-overlapping channels do not collide and can share the same TSF target.

Implementation considerations:

- **Channel info source:** `iw dev <intf> info` reports the operating channel.
  tsf-sync can query this at startup and when channels change.
- **Contention alignment is preserved.** The stagger offsets are exact multiples
  of 1024 µs (one TU). Since slot_time (9 µs) does not evenly divide 1024 µs,
  staggered APs' slot boundaries will be offset by a few µs — but the offset is
  fixed and deterministic, not drifting. In practice, the ≤ 10 µs sync target
  still holds within each co-channel group if the stagger is TU-aligned.
- **Alternative: different `beacon_int` per AP.** Setting AP0 to `beacon_int=100`
  and AP1 to `beacon_int=101` would cause beacons to naturally drift apart. But
  this is fragile — the stagger is not stable and periodically re-aligns, causing
  burst collisions. Fixed TSF offsets via tsf-sync are more predictable.

**Let them collide:** Beacons are small, sent at the lowest mandatory rate
(typically 6 Mbps in 5 GHz), and retried on failure. Simpler to implement but
wastes some airtime. Acceptable when N is small (2-3 co-channel APs). This is
the current tsf-sync behavior — all APs sync to the same TSF, beacons coincide,
and the standard beacon retry mechanism handles it. For a first deployment, this
is the recommended starting point; staggering can be added later if beacon loss
becomes measurable.

### 2B.5 HE/EHT Beacon Fields Relevant to Dense Deployment

For 802.11ax/be (WiFi 6/7), beacons carry additional IEs that affect dense
operation:

**HE Operation IE (ext 36):**
- **BSS Color** (6 bits, range 1-63): a per-AP identifier on the same channel.
  Enables OBSS PD (Overlapping BSS Preamble Detection) spatial reuse — a receiver
  can ignore inter-BSS frames below a power threshold.
- Default PE Duration: affects padding overhead in trigger-based PPDU.
- HE MCS/NSS set: per-bandwidth maximum MCS.

**BSS Color Change Announcement IE (ext 42):**
- Allows an AP to change its BSS color without disassociating clients.
- Contains the new color value (1-63) and a countdown to the switch.

**Spatial Reuse Parameter Set IE (ext 39):**
- Non-SRG OBSS PD max offset: threshold for ignoring inter-BSS frames,
  range -82 to -62 dBm.
- SRG OBSS PD min/max offset: thresholds for SRG-based spatial reuse,
  range -82 to -62 dBm.

**BSS Color assignment for dense deployment:**
- Range: 1-63 (0 = disabled/unset).
- Must be unique among co-channel APs within hearing range.
- With 6 co-channel APs: assign colors 1 through 6.
- Complementary to TSF sync: color enables spatial reuse, TSF aligns contention.

---

## 3. The Collision Problem: Probability and Scale

### 3.1 Collision Probability for N Stations

When N stations each independently draw a backoff slot uniformly from
`[0, CW]` (W = CW + 1 choices), the probability that a given station
collides with at least one other is:

```
P(collision) = 1 - ((W - 1) / W)^(N - 1)
```

This is one minus the probability that all N-1 other stations chose a
different slot.

| N (stations) | CW=15 (W=16) | CW=31 (W=32) | CW=63 (W=64) | CW=127 (W=128) |
|:------------:|:------------:|:------------:|:------------:|:--------------:|
|       5      |    22.8%     |    11.9%     |     6.1%     |      3.1%      |
|      10      |    44.0%     |    24.9%     |    13.2%     |      6.8%      |
|      20      |    70.7%     |    45.3%     |    25.8%     |     13.9%      |
|      50      |    95.7%     |    72.8%     |    53.7%     |     31.9%      |
|     100      |    99.8%     |    95.7%     |    78.9%     |     54.0%      |
| **Avg backoff** | **67.5 µs** | **139.5 µs** | **283.5 µs** | **571.5 µs** |
| **AIFS + backoff (AC_BE)** | **110.5 µs** | **182.5 µs** | **326.5 µs** | **614.5 µs** |

The bottom two rows show the cost of each CW value. Average backoff is
`CW/2 × 9 µs` (the mean of a uniform draw from [0, CW] slots). Total wait
before a first transmission attempt is AIFS + backoff — for AC_BE,
AIFS = 43 µs, so a station with CW=127 waits on average 614.5 µs before
it even attempts to transmit.

But collisions compound this. Each failed attempt doubles CW and adds another
full AIFS + backoff cycle. With 20 stations at CW=15, the 70.7% collision rate
means most stations fail their first attempt and retry at CW=31 (182.5 µs),
then some fail again at CW=63 (326.5 µs). The expected total wait across
all attempts until success is:

```
E[total] ≈ Σ  P(reach attempt k) × (AIFS + CW_k/2 × slot_time)
           k=0

For N=20:  attempt 0 (CW=15):  110.5 µs  × 1.000  =  110.5 µs
           attempt 1 (CW=31):  182.5 µs  × 0.707  =  129.0 µs
           attempt 2 (CW=63):  326.5 µs  × 0.320  =  104.5 µs
           attempt 3 (CW=127): 614.5 µs  × 0.083  =   51.0 µs
                                            Total  ≈  395 µs expected wait
```

Compare to the collision-free case (5 stations, CW=15): 110.5 µs with a 22.8%
chance of one retry. The 20-station case costs roughly 3.6× more airtime per
successful frame — and that is the airtime that TSF sync and CWmin tuning aim to
recover.

### 3.2 What Happens When TSFs Are NOT Aligned

When APs have independent, drifting TSFs, their slot boundaries do not coincide.
Consider two APs with a 4 µs TSF offset (less than one slot time of 9 µs):

```
AP1 slots: |  slot 0  |  slot 1  |  slot 2  |  slot 3  |
           0µs       9µs       18µs      27µs      36µs

AP2 slots:     |  slot 0  |  slot 1  |  slot 2  |  slot 3  |
               4µs       13µs      22µs      31µs      40µs
```

A client on AP1 transmitting at the start of its slot 2 (18 µs) lands in the
middle of AP2's slot 1. A client on AP2 transmitting at the start of its slot 1
(13 µs) partially overlaps with AP1's slot 1. These mid-slot collisions are
invisible to the backoff algorithm — neither station chose the "same" slot, yet
their transmissions overlap.

The result: frames are corrupted by partial overlaps that look like noise or
interference rather than contention. The AP sees a failed transmission but has
no signal to increase CW, or increases CW in response to what it misinterprets
as persistent interference. CW may climb higher than necessary (wasting airtime)
or not climb at all (perpetuating collisions).

### 3.3 What Happens When TSFs ARE Aligned

When all APs share the same TSF reference (within one slot time, ≤ 9 µs), their
slot boundaries coincide. A collision now means two stations chose the **same
slot number** — a clean, full-slot collision that triggers the standard CW
doubling response.

```
Aligned slots (all APs):
|  slot 0  |  slot 1  |  slot 2  |  slot 3  |  slot 4  |
0µs       9µs       18µs      27µs      36µs      45µs

Station A (AP1) picks slot 2: transmits at 18 µs
Station B (AP2) picks slot 2: transmits at 18 µs  ← clean collision
Station C (AP2) picks slot 4: transmits at 36 µs  ← no conflict
```

TSF sync does not eliminate collisions — it cannot, because contention is
inherently probabilistic. What it does is make collisions **visible** to the
protocol's feedback mechanism. CW doubling works as designed: collisions cause
exponential backoff, backoff reduces collision probability, and the system
converges to a stable operating point.

The counterintuitive result is that TSF sync may **increase** the initial
collision rate (all stations now contend in the same epoch rather than across
offset epochs), but the protocol resolves those collisions faster and more
efficiently than it handles the invisible partial-overlap collisions of
unaligned operation.

### 3.4 Worked Example: 20 Clients Across 4 APs

Consider 20 clients distributed across 4 co-channel APs (5 per AP), all using
AC_BE with default EDCA parameters (CWmin=15).

**Without TSF sync:**
- Each AP sees intra-BSS contention among 5 stations.
  P(collision) = 1 - (15/16)^4 = **22.8%** per station.
- Cross-BSS collisions are invisible due to slot misalignment. They manifest
  as elevated FCS errors and unexplained retransmissions.
- CW doubling responds to intra-BSS collisions but cannot address cross-BSS
  interference. The AP may attribute it to channel conditions and reduce MCS.

**With TSF sync:**
- All 20 stations contend in the same epoch. The effective contention is among
  20 stations, not 5.
- Initial collision rate: P = 1 - (15/16)^19 = **70.7%**. This is higher.
- But CW doubling now sees every collision. After the first round:
  - CW=31: P = 1 - (31/32)^19 = **45.3%**
  - CW=63: P = 1 - (63/64)^19 = **25.8%**
  - CW=127: P = 1 - (127/128)^19 = **13.9%**
- By the third doubling, collision probability is below the unsynced intra-BSS
  rate, and the system continues converging.

The key insight: synchronized operation shows a higher initial collision rate but
converges to a lower steady-state collision rate because the self-correction
mechanism (CW doubling) operates on complete information. Unsynced operation
has a lower visible rate but a hidden cross-BSS collision floor that cannot be
corrected by backoff.

---

## 4. hostapd Tuning for Dense Deployments

### 4.1 EDCA Parameter Tuning

The default EDCA parameters assume a lightly loaded network. In a dense
deployment with 50-100 clients sharing a channel, increasing CWmin reduces
collision probability at the cost of higher average backoff delay.

hostapd uses log₂ encoding: the parameter value `n` yields CW = 2^n - 1.

| Deployment size | Clients/channel | Recommended `wmm_ac_be_cwmin` | CWmin | Avg backoff |
|-----------------|-----------------|-------------------------------|-------|-------------|
| Small           | 5-15            | 4 (default)                   |  15   |  67.5 µs    |
| Medium          | 15-30           | 5                             |  31   |  139.5 µs   |
| Large           | 30-60           | 6                             |  63   |  283.5 µs   |
| Very large      | 60-100+         | 7                             | 127   |  571.5 µs   |

The trade-off is direct: larger CW = fewer collisions but higher mean backoff
(CW/2 × 9 µs). For latency-sensitive traffic on AC_VO/AC_VI, keep defaults —
voice and video frames are small and infrequent enough that their low CWmin
rarely causes problems.

Recommended starting configuration for a dense deployment:

```
# Best effort — increase CWmin for dense contention
wmm_ac_be_cwmin=5           # CWmin=31 (default: 4 → CWmin=15)
wmm_ac_be_cwmax=10          # CWmax=1023 (default, keep)
wmm_ac_be_aifs=3            # AIFSN=3 (default, keep)
wmm_ac_be_txop_limit=0      # No TXOP limit (default)

# Background — larger CWmin since BK traffic is delay-tolerant
wmm_ac_bk_cwmin=5           # CWmin=31 (default: 4 → CWmin=15)
wmm_ac_bk_cwmax=10          # CWmax=1023 (default)
wmm_ac_bk_aifs=7            # AIFSN=7 (default)
wmm_ac_bk_txop_limit=0

# Voice and video — keep defaults, low contention expected
wmm_ac_vo_cwmin=2            # CWmin=3
wmm_ac_vo_cwmax=3            # CWmax=7
wmm_ac_vo_aifs=2
wmm_ac_vo_txop_limit=47      # 1.504 ms

wmm_ac_vi_cwmin=3            # CWmin=7
wmm_ac_vi_cwmax=4            # CWmax=15
wmm_ac_vi_aifs=2
wmm_ac_vi_txop_limit=94      # 3.008 ms
```

### 4.2 Beacon Interval and DTIM Period

All co-channel APs should use the **same** `beacon_int` to simplify staggering.
With TSF sync, TBTT aligns, so either stagger explicitly (offset each AP's TSF
by `beacon_int / N_cochannel` TU) or accept beacon collisions (viable for ≤3
co-channel APs).

```
beacon_int=100               # 100 TU = 102.4 ms (default, good for most cases)
dtim_period=2                # Every other beacon is DTIM (default)
```

For deployments where multicast latency matters (e.g., mDNS, ARP), use
`dtim_period=1` so every beacon delivers buffered multicast. For maximum airtime
savings, `dtim_period=3` defers multicast delivery but saves beacon overhead.

### 4.3 RTS/CTS Threshold

RTS/CTS reserves the medium before large frames, mitigating hidden node problems
at the cost of overhead (RTS + SIFS + CTS + SIFS = ~50 µs per exchange).

```
rts_threshold=500            # Bytes. Frames ≥500 bytes use RTS/CTS.
                             # -1 = disabled (default)
                             # 256-1000 recommended for dense deployments
```

In dense environments with many APs, hidden nodes are common — a client near AP1
may not hear clients near AP3, even though they share a channel. RTS/CTS at
500-1000 bytes provides protection for data frames while leaving small control
frames and ACKs unprotected (they are short enough that collision cost is low).

### 4.4 BSS Color and Spatial Reuse (802.11ax)

BSS Color is orthogonal to TSF sync but complementary. While TSF sync aligns
contention timing, BSS Color enables spatial reuse — allowing a station to
transmit even when it detects an inter-BSS frame, if the received power is below
a threshold.

```
he_bss_color=1               # Range: 1-63. Must be unique per co-channel AP.
# Spatial reuse parameters (if supported by firmware):
# he_spr_sr_control=1
# he_spr_non_srg_obss_pd_max_offset=20   # -82 + 20 = -62 dBm threshold
```

Assign colors sequentially to co-channel APs. With 4 co-channel APs, use
colors 1, 2, 3, 4.

### 4.5 Channel Planning

5 GHz offers six non-overlapping 80 MHz channels:

| Channel group | Center freq | Band    | DFS required | Notes              |
|:-------------:|:-----------:|---------|:------------:|:------------------:|
| 36-48         | 42 (5210)   | UNII-1  |     No       | Preferred          |
| 52-64         | 58 (5290)   | UNII-2  |     Yes      | Radar avoidance    |
| 100-112       | 106 (5530)  | UNII-2C |     Yes      | Radar avoidance    |
| 116-128       | 122 (5610)  | UNII-2C |     Yes      | Radar avoidance    |
| 132-144       | 138 (5690)  | UNII-2C |     Yes      | Radar avoidance    |
| 149-161       | 155 (5775)  | UNII-3  |     No       | Preferred          |

With 20 NICs across 6 channels: 3-4 co-channel APs. TSF sync is most beneficial
on these co-channel groups, where 3-4 APs and their clients all contend on the
same medium.

6 GHz (WiFi 6E/7) adds 59 additional 20 MHz channels (channels 1-233), offering
significantly more spectrum and making co-channel situations rarer — but TSF sync
still matters when co-channel APs exist.

### 4.6 Complete hostapd Configuration Template

See Appendix A for a fully annotated hostapd.conf stanza covering all parameters
discussed in this section.

---

## 5. Lab Testing Plan: Measuring the Impact

### 5.1 Test Environment

**Hardware:**
- Host: single NixOS machine with N MT7925 PCIe NICs (target: 4-20)
- Each NIC runs a hostapd instance in AP mode
- tsf-sync daemon aligning TSF across all NICs

**Clients:**
- SSH-accessible devices: laptops, Raspberry Pis, or similar
- 5-10 clients per AP, targeting 50-100 total
- Each client associates with a specific AP via MAC-based filtering or SSID

**Network topology:**

```
┌────────────────────────────────────────────────────────────┐
│  NixOS Host                                                │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐       ┌──────────┐  │
│  │ NIC0 │ │ NIC1 │ │ NIC2 │ │ NIC3 │  ...  │ tsf-sync │  │
│  │ AP0  │ │ AP1  │ │ AP2  │ │ AP3  │       │  daemon  │  │
│  └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘       └──────────┘  │
│     │        │        │        │                           │
└─────┼────────┼────────┼────────┼───────────────────────────┘
      │        │        │        │
   ┌──┴──┐  ┌──┴──┐  ┌──┴──┐  ┌──┴──┐
   │C0-C4│  │C5-C9│  │C10- │  │C15- │
   │     │  │     │  │  C14│  │  C19│
   └─────┘  └─────┘  └─────┘  └─────┘
```

**Software:**
- iperf2 (not iperf3) for UDP jitter/loss measurement and parallel streams
- iw, /proc/net/wireless, debugfs for AP-side metrics
- phc2sys / tsf-ptp for TSF synchronization

### 5.2 Metrics to Collect

**AP-side metrics** (polled every 1-5 seconds):

| Metric | Source | Unit | Notes |
|--------|--------|------|-------|
| TX retries per station | `iw dev <intf> station dump` | count | delta between polls |
| TX failed per station | `iw dev <intf> station dump` | count | frames dropped after max retries |
| Airtime utilization | `iw dev <intf> survey dump` | % | active/busy/receive/transmit time |
| FCS error count | `iw dev <intf> survey dump` | count | indicates corrupted frames received |
| TSF offset from primary | tsf-sync log or `phc2sys` | µs | should converge to ≤10 µs |
| Channel noise floor | `iw dev <intf> survey dump` | dBm | environmental baseline |
| Associated station count | `iw dev <intf> station dump` | count | verify expected client count |

**Client-side metrics** (per iperf2 run):

| Metric | Source | Unit | Notes |
|--------|--------|------|-------|
| UDP throughput | iperf2 `-u` | Mbps | per-stream and aggregate |
| UDP jitter | iperf2 `-u` | ms | interpacket arrival variation |
| UDP packet loss | iperf2 `-u` | % | lost/(lost+received) |
| TCP throughput | iperf2 (default TCP) | Mbps | per-stream |
| RTT (ping) | ping | ms | min/avg/max/stddev |
| RSSI | `iw dev <intf> link` | dBm | signal strength to AP |
| TX bitrate | `iw dev <intf> link` | Mbps | current MCS selection |

**System-level metrics** (polled every 1-5 seconds):

| Metric | Source | Unit | Notes |
|--------|--------|------|-------|
| CPU usage | `/proc/stat` or `mpstat` | % | tsf-sync overhead |
| tsf-ptp adjtime calls | tsf-sync counters | count/s | sync activity |
| phc2sys offset | phc2sys log | ns | PTP-level offset |
| Memory usage | `/proc/meminfo` | MB | baseline |

### 5.3 Automation Framework

Tests are orchestrated by a shell script that manages the full lifecycle:

```bash
#!/usr/bin/env bash
# test-runner.sh — orchestrate a single test phase

PHASE="$1"          # e.g., "phase0-baseline"
DURATION=60         # measurement duration (seconds)
WARMUP=30           # warm-up before measurement
COOLDOWN=10         # cool-down after measurement
RUNS=5              # repetitions per configuration
RESULT_DIR="results/${PHASE}/$(date +%Y%m%d-%H%M%S)"

mkdir -p "$RESULT_DIR"

for run in $(seq 1 "$RUNS"); do
    run_dir="${RESULT_DIR}/run-${run}"
    mkdir -p "$run_dir"

    # 1. Configure hostapd (phase-specific config)
    configure_hostapd "$PHASE"

    # 2. Start or stop tsf-sync based on phase
    case "$PHASE" in
        phase0*) systemctl stop tsf-sync ;;
        *)       systemctl start tsf-sync ;;
    esac

    # 3. Wait for warm-up (clients associate, TSF converges)
    sleep "$WARMUP"

    # 4. Start AP-side metric collection (background)
    collect_ap_metrics "$run_dir" "$DURATION" &
    AP_PID=$!

    # 5. Start iperf2 on all clients via SSH
    run_iperf_clients "$run_dir" "$DURATION"

    # 6. Wait for AP metric collection to finish
    wait "$AP_PID"

    # 7. Cool-down
    sleep "$COOLDOWN"

    # 8. Collect final station dump
    iw dev wlan0 station dump > "$run_dir/station-dump-final.txt"
done

# 9. Aggregate results across runs
compute_stats "$RESULT_DIR"
```

Client iperf2 sessions are started via SSH with key-based authentication:

```bash
run_iperf_clients() {
    local dir="$1" duration="$2"
    for client in "${CLIENTS[@]}"; do
        ssh "$client" "iperf -c $AP_IP -u -b 50M -t $duration -i 1" \
            > "$dir/iperf-${client}.txt" 2>&1 &
    done
    wait  # wait for all clients to finish
}
```

Output is stored as timestamped CSV in per-run directories:
`results/<phase>/<timestamp>/run-<N>/`.

### 5.4 Statistical Rigor

Each configuration is tested for **5-10 runs** of 60 seconds each. Reported
metrics use the mean across runs with a **95% confidence interval** via the
t-distribution:

```
CI = x̄ ± t(0.025, N-1) × s / √N
```

Where x̄ is the sample mean, s is the sample standard deviation, and N is the
number of runs. For N=5, t(0.025, 4) ≈ 2.776. For N=10, t(0.025, 9) ≈ 2.262.

Additional rigor requirements:

- **Warm-up:** 30 seconds before measurement to allow client association, TSF
  convergence (typically ≤5 seconds), and TCP slow-start.
- **Cool-down:** 10 seconds between runs to drain queues and reset CW.
- **Environmental documentation:** Record ambient RF conditions (other networks
  visible, time of day, physical AP placement). Use `iw dev <intf> scan` before
  the test session to document neighboring BSSes.
- **Control channel:** Include at least one AP on a non-overlapping channel as
  a control. Its metrics should be unaffected by TSF sync.

### 5.5 Phase 0: Baseline (No TSF Sync, Default hostapd)

**Configuration:**
- tsf-sync: **off**
- EDCA: all defaults (CWmin=15 for BE/BK)
- `beacon_int=100`, `dtim_period=2`
- `rts_threshold=-1` (disabled)
- No BSS Color

**Expected observations:**
- TSF offsets between APs: freely drifting, diverging over time
- Retry rate on co-channel APs: 10-30% (elevated due to cross-BSS interference)
- Retry rate on non-overlapping channel APs: 2-5% (baseline, intra-BSS only)
- Throughput: limited by contention overhead and hidden collisions

**Measurements:**
All metrics from §5.2, with emphasis on retry rate delta between co-channel and
non-overlapping-channel APs. This delta quantifies the cost of cross-BSS
interference that TSF sync aims to reduce.

### 5.6 Phase 1: TSF Sync Enabled (Default hostapd)

**Configuration:**
- tsf-sync: **on** (5 µs threshold)
- All other parameters: same as Phase 0

**Expected observations:**
- TSF offsets converge to ≤10 µs within 5 seconds (verify against
  [`wifi-timing.md`](wifi-timing.md) line 62 target)
- Co-channel retry rate decreases as cross-BSS collisions become visible
  to the backoff algorithm
- Possible transient increase in contention during convergence
- Non-overlapping channel APs: no change (control)

**Comparison with Phase 0:**
- Primary metric: co-channel retry rate reduction
- Secondary: throughput improvement, jitter reduction
- Control: non-overlapping channel metrics should be unchanged (hypothesis H4)

### 5.7 Phase 2: Systematic EDCA Tuning (TSF Sync On)

With TSF sync enabled, sweep individual EDCA parameters to find optimal values.
Each test varies **one parameter at a time** from the Phase 1 baseline.

**Test matrix:**

| Test ID | Parameter             | Value  | CWmin | CWmax | AIFS | RTS (bytes) |
|:-------:|-----------------------|--------|:-----:|:-----:|:----:|:-----------:|
| 2-01    | `wmm_ac_be_cwmin`     | 4      |  15   | 1023  |  3   |     off     |
| 2-02    | `wmm_ac_be_cwmin`     | 5      |  31   | 1023  |  3   |     off     |
| 2-03    | `wmm_ac_be_cwmin`     | 6      |  63   | 1023  |  3   |     off     |
| 2-04    | `wmm_ac_be_cwmin`     | 7      | 127   | 1023  |  3   |     off     |
| 2-05    | `wmm_ac_be_aifs`      | 3      |  15   | 1023  |  3   |     off     |
| 2-06    | `wmm_ac_be_aifs`      | 4      |  15   | 1023  |  4   |     off     |
| 2-07    | `wmm_ac_be_aifs`      | 5      |  15   | 1023  |  5   |     off     |
| 2-08    | `wmm_ac_be_aifs`      | 7      |  15   | 1023  |  7   |     off     |
| 2-09    | `wmm_ac_be_cwmax`     | 10     |  15   | 1023  |  3   |     off     |
| 2-10    | `wmm_ac_be_cwmax`     | 8      |  15   |  255  |  3   |     off     |
| 2-11    | `wmm_ac_be_cwmax`     | 6      |  15   |   63  |  3   |     off     |
| 2-12    | `rts_threshold`       | -1     |  15   | 1023  |  3   |     off     |
| 2-13    | `rts_threshold`       | 500    |  15   | 1023  |  3   |     500     |
| 2-14    | `rts_threshold`       | 256    |  15   | 1023  |  3   |     256     |

5 runs per test ID, 60 seconds each. Plot each metric against the swept
parameter value and identify the inflection point (the "knee") where further
increases yield diminishing returns.

### 5.8 Phase 3: Combined Optimization

Combine the best values from Phase 2:

- Best `wmm_ac_be_cwmin` from tests 2-01 through 2-04
- Best `wmm_ac_be_aifs` from tests 2-05 through 2-08
- RTS/CTS decision from tests 2-12 through 2-14
- TSF sync: on

Run 10 runs (more than Phase 2 for tighter confidence intervals).

**Final comparison table:**

| Metric                  | Phase 0 (baseline) | Phase 1 (sync only) | Phase 3 (optimized) |
|-------------------------|:------------------:|:-------------------:|:-------------------:|
| Co-channel retry rate   |       ±CI          |        ±CI          |        ±CI          |
| Aggregate throughput    |       ±CI          |        ±CI          |        ±CI          |
| Mean UDP jitter         |       ±CI          |        ±CI          |        ±CI          |
| UDP packet loss         |       ±CI          |        ±CI          |        ±CI          |
| Mean ping RTT           |       ±CI          |        ±CI          |        ±CI          |
| Airtime utilization     |       ±CI          |        ±CI          |        ±CI          |
| Control AP retry rate   |       ±CI          |        ±CI          |        ±CI          |

### 5.9 Data Collection Scripts

**`collect_ap_metrics.sh`** — polls AP-side metrics at 1-second intervals:

```bash
#!/usr/bin/env bash
# collect_ap_metrics.sh <output_dir> <duration_seconds>
OUTPUT="$1/ap-metrics.csv"
DURATION="$2"
INTERFACES=(wlan0 wlan1 wlan2 wlan3)  # adjust per setup

echo "timestamp,interface,tx_retries,tx_failed,rx_bytes,tx_bytes,signal,airtime_active,airtime_busy" \
    > "$OUTPUT"

END=$((SECONDS + DURATION))
while [ "$SECONDS" -lt "$END" ]; do
    TS=$(date +%s.%N)
    for intf in "${INTERFACES[@]}"; do
        # Station dump: aggregate retries across all stations
        retries=$(iw dev "$intf" station dump | awk '/tx retries:/{s+=$3}END{print s+0}')
        failed=$(iw dev "$intf" station dump | awk '/tx failed:/{s+=$3}END{print s+0}')
        rx=$(iw dev "$intf" station dump | awk '/rx bytes:/{s+=$3}END{print s+0}')
        tx=$(iw dev "$intf" station dump | awk '/tx bytes:/{s+=$3}END{print s+0}')
        signal=$(iw dev "$intf" station dump | awk '/signal:/{print $2; exit}')

        # Survey dump: airtime
        active=$(iw dev "$intf" survey dump | awk '/active time:/{print $3; exit}')
        busy=$(iw dev "$intf" survey dump | awk '/busy time:/{print $3; exit}')

        echo "${TS},${intf},${retries},${failed},${rx},${tx},${signal},${active},${busy}" \
            >> "$OUTPUT"
    done
    sleep 1
done
```

**`run_iperf_clients.sh`** — launches iperf2 on all clients:

```bash
#!/usr/bin/env bash
# run_iperf_clients.sh <output_dir> <duration_seconds> <server_ip>
OUTPUT_DIR="$1"
DURATION="$2"
SERVER="$3"
CLIENTS=(client0 client1 client2 client3)  # SSH hostnames

for client in "${CLIENTS[@]}"; do
    ssh -o ConnectTimeout=5 "$client" \
        "iperf -c $SERVER -u -b 20M -t $DURATION -i 1 -p 5001" \
        > "${OUTPUT_DIR}/iperf-udp-${client}.txt" 2>&1 &
done
wait

# Also collect client-side link info
for client in "${CLIENTS[@]}"; do
    ssh "$client" "iw dev wlan0 link" > "${OUTPUT_DIR}/link-${client}.txt" 2>&1
done
```

**`compute_stats.sh`** — aggregates results across runs:

```bash
#!/usr/bin/env bash
# compute_stats.sh <result_dir>
# Computes mean, stddev, 95% CI for key metrics across run-* subdirectories
RESULT_DIR="$1"

# Extract per-run retry deltas from CSV
for run_dir in "$RESULT_DIR"/run-*; do
    # Final minus initial tx_retries from ap-metrics.csv
    awk -F, 'NR==2{first=$3} END{print $3-first}' "$run_dir/ap-metrics.csv"
done | awk '{
    sum += $1; sumsq += $1*$1; n++
} END {
    mean = sum/n
    var = (sumsq - sum*sum/n) / (n-1)
    sd = sqrt(var)
    # t(0.025, n-1) approximation for small n
    if (n==5) t=2.776; else if (n==10) t=2.262; else t=2.0
    ci = t * sd / sqrt(n)
    printf "retry_delta: mean=%.1f sd=%.1f ci=%.1f (n=%d)\n", mean, sd, ci, n
}'
```

### 5.10 What Success Looks Like

**Pre-registered hypotheses:**

| ID | Hypothesis | Metric | Expected range |
|----|-----------|--------|---------------|
| H1 | TSF sync alone reduces retry rate on co-channel APs | Retry rate delta (Phase 1 vs 0) | -10% to -30% |
| H2 | Optimal CWmin for 50-100 clients ≈ 5-6 (log₂) | Phase 2 knee in retry vs CWmin | CWmin=31 or 63 |
| H3 | Combined optimization yields significant improvement | Phase 3 vs Phase 0 | +15-40% throughput, -20-50% jitter |
| H4 | Non-overlapping channel APs are unaffected (control) | Control AP retry rate across phases | <5% change |

**Red flags to watch for:**

- TSF offsets not converging within 10 seconds → investigate tsf-sync/driver issue
- Control AP metrics changing between phases → environmental interference or
  test contamination
- Retry rate increasing with TSF sync → possible beacon collision issue,
  consider staggering (§2B.4)
- CPU usage spike during measurement → tsf-sync overhead, check sync mode
  (see §6.4)
- iperf2 reporting 0 throughput → client disassociated, check `dmesg`

---

## 6. Advanced Topics

### 6.1 TSF Sync and Rate Adaptation

MT7925 rate selection is firmware-controlled and not tunable from the host
(see [`mt7925-rate-selection.md`](mt7925-rate-selection.md)). The firmware
adapts MCS based on observed packet error rate (PER): high PER → lower MCS,
low PER → higher MCS.

Unaligned TSF causes hidden cross-BSS collisions that inflate PER, pushing the
firmware toward lower MCS rates unnecessarily. With TSF sync, collisions become
visible and are resolved via CW doubling rather than rate reduction.

**How to measure:** Compare per-station TX bitrate distributions between Phase 0
and Phase 1. Hypothesis: TSF sync shifts the distribution toward higher MCS
indices, as fewer phantom collisions trigger rate adaptation.

### 6.2 Multi-Channel vs Single-Channel

TSF sync provides the strongest benefit on **shared channels** where multiple APs
contend on the same medium. On non-overlapping channels (e.g., AP on channel 36
and AP on channel 149), there is no RF contention and TSF alignment has no effect
on EDCA operation.

However, TSF sync still provides secondary benefits:
- **Beacon timing:** Aligned TSF enables coordinated beacon scheduling across
  channels, useful for fast roaming (802.11r) and consistent DTIM delivery.
- **System simplicity:** A single time reference for all APs simplifies logging,
  debugging, and correlation of events across interfaces.

### 6.3 The 10 µs Budget

The slot time for OFDM is 9 µs. The recommended TSF sync target is ≤ 10 µs
(see [`wifi-timing.md`](wifi-timing.md) line 62). This means synchronized APs are
within one slot time of each other — close enough that their slot boundaries
nearly coincide. A station on AP1 that begins transmitting at the start of slot N
is within one slot of the same moment as slot N on AP2.

The ≤ 10 µs target (see [`wifi-timing.md`](wifi-timing.md) line 59 for the
one-slot-time contention coordination requirement) is achievable for drivers with
register-based TSF access, which the MT7925 supports via the `set_tsf` /
`get_tsf` mac80211 callbacks.

### 6.4 Scaling Considerations

As the number of NICs grows, the choice of sync mode matters for system overhead.
The [`comparison.md`](comparison.md) scaling analysis (lines 189-224) quantifies
this:

- **Mode A (phc2sys):** Syscalls scale linearly with card count — 120 syscalls per
  cycle at 60 cards, 202 at 100 cards. Works at 24 cards, becomes measurable at
  60+.
- **Mode C (io_uring):** 2 syscalls per cycle regardless of card count. Batch
  submission amortizes the cost of all TSF read/write operations into a single
  io_uring submission and completion.

For a lab test with 4-20 NICs, Mode A (phc2sys) is sufficient. For production
deployments at 60+ NICs, Mode C provides significantly lower system overhead.

See [`architecture.md`](architecture.md) lines 31-33 for details on the
phc2sys-based sync flow and the read-modify-write nature of `adjtime`.

---

## 7. References

### Standards
- IEEE 802.11-2020, Clause 10.22.2 (EDCA channel access)
- IEEE 802.11-2020, Clause 10.23 (DCF)
- IEEE 802.11-2020, Clause 9.2.5 (TSF)
- IEEE 802.11-2020, Table 9-155 (default EDCA parameter set)
- IEEE 802.11ax-2021, Clause 26.17 (BSS Color / OBSS PD-based spatial reuse)

### Software documentation
- hostapd.conf — hostapd configuration file reference
- iperf2 — network bandwidth measurement tool

### Project cross-references
- [`wifi-timing.md`](wifi-timing.md) — Slot times, SIFS/DIFS, beacon cycle,
  sync target (lines 27-34, 40-46, 59, 62)
- [`architecture.md`](architecture.md) — PTP sync modes, phc2sys flow
  (lines 31-33)
- [`testing.md`](testing.md) — hwsim and microVM test infrastructure
  (this document complements with real-hardware testing)
- [`comparison.md`](comparison.md) — Syscall-per-cycle scaling analysis
  (lines 189-224)
- [`mt7925-rate-selection.md`](mt7925-rate-selection.md) — Firmware-controlled
  rate selection, not host-tunable

---

## Appendix A: Complete hostapd.conf Template

```ini
# =============================================================================
# hostapd.conf — Dense deployment with TSF sync
# =============================================================================
# This template is for one AP instance. Replicate per NIC, changing interface,
# BSSID, channel, and BSS color.

# -- Interface ----------------------------------------------------------------
interface=wlan0
driver=nl80211
hw_mode=a                     # 5 GHz
channel=36                    # Adjust per channel plan (§4.5)
# For 80 MHz operation:
# ieee80211ac=1
# vht_oper_chwidth=1          # 80 MHz
# vht_oper_centr_freq_seg0_idx=42

# -- SSID and security -------------------------------------------------------
ssid=dense-lab
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=lab-test-only

# -- Beacon and DTIM ----------------------------------------------------------
beacon_int=100                # 100 TU (102.4 ms) — same across all APs
dtim_period=2                 # DTIM every other beacon

# -- EDCA parameters (dense-optimized for AC_BE) ------------------------------
wmm_enabled=1

# Best effort — increased CWmin for dense contention
wmm_ac_be_cwmin=5             # CWmin = 2^5 - 1 = 31 (default: 4 → 15)
wmm_ac_be_cwmax=10            # CWmax = 2^10 - 1 = 1023 (default)
wmm_ac_be_aifs=3              # AIFSN = 3 (default)
wmm_ac_be_txop_limit=0        # No TXOP limit (default)

# Background — also increased CWmin
wmm_ac_bk_cwmin=5             # CWmin = 31 (default: 4 → 15)
wmm_ac_bk_cwmax=10            # CWmax = 1023 (default)
wmm_ac_bk_aifs=7              # AIFSN = 7 (default)
wmm_ac_bk_txop_limit=0

# Voice — keep defaults for low-latency
wmm_ac_vo_cwmin=2             # CWmin = 3
wmm_ac_vo_cwmax=3             # CWmax = 7
wmm_ac_vo_aifs=2
wmm_ac_vo_txop_limit=47       # 1.504 ms (47 × 32 µs)

# Video — keep defaults
wmm_ac_vi_cwmin=3             # CWmin = 7
wmm_ac_vi_cwmax=4             # CWmax = 15
wmm_ac_vi_aifs=2
wmm_ac_vi_txop_limit=94       # 3.008 ms (94 × 32 µs)

# -- RTS/CTS ------------------------------------------------------------------
rts_threshold=500             # Enable RTS/CTS for frames ≥ 500 bytes

# -- 802.11ax (HE) ------------------------------------------------------------
ieee80211ax=1
he_bss_color=1                # Range 1-63, unique per co-channel AP
# he_spr_sr_control=1         # Enable spatial reuse (if firmware supports)
# he_spr_non_srg_obss_pd_max_offset=20

# -- Country and regulatory ---------------------------------------------------
country_code=US
ieee80211d=1
ieee80211h=1                  # Required for 5 GHz DFS channels
```

## Appendix B: iperf2 Command Reference

```bash
# --- UDP tests ---------------------------------------------------------------

# Client: 20 Mbps UDP stream for 60 seconds, report every 1 second
iperf -c $SERVER_IP -u -b 20M -t 60 -i 1

# Client: 50 Mbps UDP, 10 parallel streams
iperf -c $SERVER_IP -u -b 50M -t 60 -i 1 -P 10

# Client: UDP with specific packet size (1400 bytes)
iperf -c $SERVER_IP -u -b 20M -t 60 -i 1 -l 1400

# Server: listen for UDP
iperf -s -u -i 1

# --- TCP tests ---------------------------------------------------------------

# Client: TCP throughput for 60 seconds
iperf -c $SERVER_IP -t 60 -i 1

# Client: TCP with 10 parallel streams
iperf -c $SERVER_IP -t 60 -i 1 -P 10

# Server: listen for TCP
iperf -s -i 1

# --- Bidirectional -----------------------------------------------------------

# Client: simultaneous TX and RX (tradeoff mode)
iperf -c $SERVER_IP -u -b 20M -t 60 -i 1 -d

# --- Key flags ---------------------------------------------------------------
# -c HOST    Client mode, connect to HOST
# -s         Server mode
# -u         UDP (default is TCP)
# -b RATE    Target bandwidth (UDP only), e.g., 20M, 100M
# -t SEC     Duration in seconds
# -i SEC     Report interval in seconds
# -P N       Parallel streams
# -l BYTES   Buffer/packet length
# -p PORT    Server port (default: 5001)
# -d         Bidirectional (simultaneous TX and RX)
# -w SIZE    TCP window size / UDP buffer size
```

## Appendix C: Metric Collection One-Liners

```bash
# TSF value for an interface (requires debugfs or tsf-ptp)
cat /sys/kernel/debug/ieee80211/phy0/tsf

# Station dump: all associated clients and their stats
iw dev wlan0 station dump

# Survey dump: channel utilization and noise
iw dev wlan0 survey dump

# Per-station retries (extract from station dump)
iw dev wlan0 station dump | awk '/^Station/{sta=$2} /tx retries:/{print sta, $3}'

# Per-station signal strength
iw dev wlan0 station dump | awk '/^Station/{sta=$2} /signal:/{print sta, $2, "dBm"}'

# Airtime utilization percentage
iw dev wlan0 survey dump | awk '/active time:/{a=$3} /busy time:/{printf "%.1f%%\n", $3/a*100}'

# Neighboring BSSes (scan for environmental documentation)
iw dev wlan0 scan | awk '/^BSS/{bss=$2} /SSID:/{print bss, $2}'

# Ping with timestamps (100 pings, 0.1s interval)
ping -c 100 -i 0.1 -D $AP_IP

# Watch TSF offsets in real time (if tsf-sync exposes them)
watch -n 1 'cat /sys/kernel/debug/tsf-sync/offsets'

# CPU usage of tsf-sync process
pidstat -p $(pgrep tsf-sync) 1

# Count associated stations across all interfaces
for intf in wlan0 wlan1 wlan2 wlan3; do
    echo -n "$intf: "
    iw dev "$intf" station dump | grep -c '^Station'
done
```
