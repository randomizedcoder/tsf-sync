# Userspace Tool: `tsf-sync`

With the kernel module handling PTP clock registration and `ptp4l` handling synchronization, the userspace tool is a lightweight orchestrator.

---

## Responsibilities

1. **Discovery** — Walk `/sys/class/ieee80211/`, identify each phy's driver, locate its PTP clock (`/dev/ptpN`).
2. **Configuration generation** — Produce a `ptp4l` config file with the right clock topology.
3. **Lifecycle management** — Start/stop `ptp4l` instances, load/unload the `tsf-ptp` kernel module.
4. **Health monitoring** — Poll `ptp4l` status via `pmc` (PTP management client), track drift, log warnings, detect failed cards.
5. **Hot-plug handling** — Watch for card add/remove events (inotify on `/sys/class/ieee80211/`), reconfigure `ptp4l` dynamically.

## What It Does NOT Do

- Synchronize clocks (that's `ptp4l`)
- Read or write TSF directly (that's the kernel module)
- Implement any timing protocol (that's IEEE 1588)

---

## CLI Interface

```
tsf-sync discover          # List WiFi cards and their PTP clock status
tsf-sync config            # Generate ptp4l configuration
tsf-sync start             # Load module, start ptp4l, begin monitoring
tsf-sync status            # Show sync health for all cards
tsf-sync stop              # Stop ptp4l, unload module
```

### `tsf-sync discover`

Walks sysfs, identifies each WiFi card, and reports:

```
PHY      DRIVER           HARDWARE         PTP CLOCK    STATUS
phy0     iwlwifi          Intel AX210      /dev/ptp0    native PTP
phy1     mt76             MT7925           /dev/ptp1    tsf-ptp module
phy2     mt76             MT7925           /dev/ptp2    tsf-ptp module
phy3     brcmfmac         BCM43455         —            unsupported (FullMAC)
```

### `tsf-sync config`

Generates a `ptp4l.conf` based on discovered topology:

```
tsf-sync config --primary phy0 --output /etc/ptp4l-tsf.conf
```

### `tsf-sync status`

Queries `ptp4l` via `pmc` and displays health:

```
CARD         PTP CLOCK    STATE      OFFSET     PATH DELAY
phy0 (pri)   /dev/ptp0    MASTER     —          —
phy1         /dev/ptp1    SLAVE      +12 ns     1.2 µs
phy2         /dev/ptp2    SLAVE      -8 ns      1.1 µs
```

---

## Daemon Mode

```
tsf-sync daemon --primary phy0 --interval 10s --log-level info
```

Runs continuously:

1. Discover cards at startup
2. Load `tsf-ptp` module if needed
3. Generate and write `ptp4l.conf`
4. Spawn `ptp4l` as a child process
5. Enter monitoring loop:
   - Periodically query health via `pmc`
   - Watch for hot-plug events (inotify on `/sys/class/ieee80211/`)
   - On topology change: regenerate config, signal `ptp4l` to reload
   - On `ptp4l` crash: restart with backoff
6. On shutdown signal: stop `ptp4l`, unload module

---

## Discovery Implementation

Walk `/sys/class/ieee80211/phyN/` for each phy:

1. Read `device/driver` symlink to identify vendor (`iwlwifi`, `mt7925e`, etc.)
2. Check for existing PTP clock:
   - Native (Intel): look in `device/ptp/` for existing PTP clock index
   - tsf-ptp module: look for PTP clock registered by our module
3. If no PTP clock exists, flag card as needing `tsf-ptp` module
4. Map PTP clock index to `/dev/ptpN` path
5. Determine capabilities based on driver:
   - Can this driver `set_tsf`? (Intel can't — PTP only, and only via frequency discipline)
   - Is TSF access register-based or firmware-mediated? (affects latency estimate)

---

## Configuration Generation

Given discovered cards, generate a `ptp4l.conf`:

```ini
[global]
clockClass              248         # application-specific
priority1               128
priority2               128
domainNumber            42          # avoid conflicts with other PTP domains
slaveOnly               0

# Primary card — grandmaster
[/dev/ptp0]
masterOnly              1

# Secondary cards — slaves
[/dev/ptp1]
slaveOnly               1

[/dev/ptp2]
slaveOnly               1
```

### Primary selection logic

When `--primary auto`:
1. Prefer Intel cards with native PTP (best clock quality)
2. Among non-Intel, prefer register-based TSF (lowest latency)
3. Exclude read-only cards from primary consideration
4. If no cards have PTP clocks, suggest loading `tsf-ptp` module
