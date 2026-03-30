# Error Handling

---

## Kernel Module Errors

| Error | Cause | Handling |
|-------|-------|---------|
| `get_tsf` returns 0 | Card in reset, no active VIF, firmware busy | Return `-EIO` from `gettime64`. `ptp4l` logs a warning and retries. |
| `set_tsf` fails | Card removed, firmware crash | Return `-EIO` from `settime64`. `ptp4l` logs and retries. |
| Card hot-unplug | PCIe/USB removal | `ptp_clock_unregister()` in the remove callback. `ptp4l` detects clock disappearance. |
| No VIF active | Interface is down | Return `-ENODEV`. `tsf-sync` monitors and warns user. |
| mac80211 lock contention | Another operation in progress | Wait for lock (normal kernel behavior). Should be brief. |

---

## Userspace Tool Errors

| Error | Handling |
|-------|---------|
| `tsf-ptp` module not loaded | Attempt to load; if that fails, warn and list unsupported cards |
| `ptp4l` crashes | Restart with exponential backoff. Log the failure and exit code. |
| Card disappears during operation | Regenerate `ptp4l` config, signal `ptp4l` to reload (SIGHUP) |
| Card appears (hot-plug) | Discover new card, load PTP clock, regenerate config, signal `ptp4l` |
| All cards gone | Stop `ptp4l`, wait for cards to reappear |
| `pmc` query fails | Log warning, skip health check for this cycle |
| Config generation fails | Log error with details, do not start `ptp4l` with bad config |

---

## Health Monitoring

The `tsf-sync` daemon periodically queries `ptp4l` via `pmc` (PTP management client):

- **Clock offset** per card — should be converging toward zero
- **Port state** — INITIALIZING → LISTENING → SLAVE → LOCKED progression
- **Path delay** — should be stable; large variance indicates problems

### Health States

```
Converging ──(offset < threshold)──→ Healthy
    ↑                                    │
    └──(offset > threshold)──────────────┘

Healthy ──(errors or offset spike)──→ Degraded ──(persistent)──→ Failed
    ↑                                     │
    └──(recovery)─────────────────────────┘

Any state ──(card disappears)──→ Removed
```

- **Converging:** Recently started. Offset still large but trending toward zero. Normal for the first few sync cycles.
- **Healthy:** Offset within tolerance, state is SLAVE or LOCKED.
- **Degraded:** Offset growing, state flapping, or repeated errors. Still attempting sync.
- **Failed:** Clock disappeared, persistent errors, or `ptp4l` reports the clock is unusable.
- **Removed:** Card physically gone. Cleaned up. If it reappears, re-discovered as new.

Cards that are Failed are excluded from the `ptp4l` config on the next regeneration cycle.
