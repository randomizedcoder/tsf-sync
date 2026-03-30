/* SPDX-License-Identifier: GPL-2.0 */
#ifndef TSF_PTP_H
#define TSF_PTP_H

#include <linux/ptp_clock_kernel.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <net/mac80211.h>

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
};

#endif /* TSF_PTP_H */
