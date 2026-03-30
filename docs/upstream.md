# Upstream Roadmap

> **Status: Placeholder — to be completed in Phase 3**

---

## Table of Contents

- [Goal](#goal)
- [Priority Targets](#priority-targets)
- [Patch Strategy](#patch-strategy)
- [Kernel Maintainer Contacts](#kernel-maintainer-contacts)
- [Patch Template](#patch-template)
- [Submission Process](#submission-process)
- [What Changes When Drivers Go Native](#what-changes-when-drivers-go-native)

---

## Goal

Long-term, every WiFi driver should register its own PTP hardware clock — the same pattern Intel's `iwlwifi` already uses. The `tsf-ptp` out-of-tree module is a stopgap and proof of concept. Once per-driver patches are upstream, the module becomes unnecessary.

---

## Priority Targets

<!-- TODO: Rank drivers by upstream patch priority
  Criteria:
  - Active maintainer engagement
  - Register-based TSF (easier to implement, lower latency)
  - Large user base
  - Modern hardware (WiFi 6/6E/7)

  Initial ranking:
  1. mt76 — Felix Fietkau, active, register-based TSF for mt7915/7996
  2. ath9k — well-understood, direct register access, large deployed base
  3. ath11k/ath12k — modern Qualcomm, active development
  4. rtw89 — Realtek WiFi 6/6E, growing user base
-->

## Patch Strategy

<!-- TODO: Document approach
  - Start with one driver as proof of concept (mt76 or ath9k)
  - Small, self-contained patch: add ptp_clock_info to the driver
  - Mirror iwlwifi's approach (ptp.c file within driver directory)
  - Address review feedback, iterate
  - Once first driver accepted, pattern is established for others
-->

## Kernel Maintainer Contacts

<!-- TODO: Document key contacts
  - mt76: Felix Fietkau <nbd@nbd.name>
  - ath9k/ath10k: Toke Høiland-Jørgensen <toke@toke.dk>
  - ath11k/ath12k: Jeff Johnson <jjohnson@kernel.org>
  - rtw88/rtw89: Ping-Ke Shih <pkshih@realtek.com>
  - mac80211 core: Johannes Berg <johannes@sipsolutions.net>
  - PTP subsystem: Richard Cochran <richardcochran@gmail.com>
-->

## Patch Template

<!-- TODO: Create a template based on iwlwifi's PTP implementation
  - Required functions: gettime64, settime64, adjtime, getcrosststamp
  - Optional: adjfine (only if hardware supports frequency adjustment)
  - Registration in driver probe, deregistration in remove
  - Cross-timestamp implementation using existing get_tsf
-->

## Submission Process

<!-- TODO: Document Linux kernel patch submission
  - checkpatch.pl validation
  - get_maintainer.pl for CC list
  - Cover letter explaining the use case (multi-card TSF sync)
  - Reference the tsf-ptp module as prior art
  - Mailing list: linux-wireless@vger.kernel.org
-->

## What Changes When Drivers Go Native

<!-- TODO: Document the impact on tsf-sync
  - tsf-ptp module becomes unnecessary for upstreamed drivers
  - tsf-sync discovery detects native PTP vs tsf-ptp
  - No changes to ptp4l configuration
  - tsf-sync remains useful for orchestration, health monitoring
  - Eventually: tsf-ptp module only needed for drivers unlikely to be upstreamed
-->
