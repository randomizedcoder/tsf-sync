/* SPDX-License-Identifier: GPL-2.0 */
#ifndef TSF_PTP_H
#define TSF_PTP_H

#include <linux/ptp_clock_kernel.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/atomic.h>
#include <net/mac80211.h>

enum tsf_ptp_sync_mode {
	TSF_SYNC_MODE_PTP	= 0,
	TSF_SYNC_MODE_KERNEL	= 1,
	TSF_SYNC_MODE_CHARDEV	= 2,
};

/**
 * struct tsf_ptp_card - Per-radio PTP clock state
 * @ptp_info:	PTP clock info structure (ops, name, etc.)
 * @ptp_clock:	Registered PTP clock (NULL if registration failed)
 * @hw:		Pointer to the mac80211 ieee80211_hw
 * @vif:	Active virtual interface (NULL if no VIF is up)
 * @lock:	Protects vif pointer; must not be held across TSF ops
 * @list:	Linked list entry for global card list
 * @name:	Human-readable name (e.g., "tsf-ptp-phy0")
 * @phy_name:	PHY name from wiphy (e.g., "phy0")
 * @is_primary:	True if this card is the sync primary (Mode B)
 * @last_offset_ns:	Last measured offset in ns (Mode B, readable via sysfs)
 * @sync_count:	Completed sync cycles for this card (Mode B)
 * @sync_error_count:	Sync errors for this card (Mode B)
 */
struct tsf_ptp_card {
	struct ptp_clock_info	ptp_info;
	struct ptp_clock	*ptp_clock;
	struct ieee80211_hw	*hw;
	struct ieee80211_vif	*vif;
	struct mutex		lock;
	struct list_head	list;
	char			name[32];
	char			phy_name[32];
	bool			is_primary;
	s64			last_offset_ns;
	atomic64_t		sync_count;
	atomic64_t		sync_error_count;
};

#endif /* TSF_PTP_H */
