// SPDX-License-Identifier: GPL-2.0
/*
 * tsf-ptp: Expose WiFi TSF timers as PTP hardware clocks
 *
 * For any mac80211 WiFi driver that implements get_tsf/set_tsf,
 * this module registers a PTP clock (/dev/ptpN) that maps:
 *   - ptp_clock_info.gettime64  → ieee80211_ops.get_tsf
 *   - ptp_clock_info.settime64  → ieee80211_ops.set_tsf
 *   - ptp_clock_info.adjtime    → get_tsf + offset + set_tsf
 *   - ptp_clock_info.getcrosststamp → get_tsf bracketed with ktime
 *
 * NOTE: This module uses mac80211 internal APIs. It must be built
 * against a full kernel source tree. This is inherently fragile
 * across kernel versions — long-term, per-driver PTP patches should
 * go upstream.
 *
 * Locking model:
 *   - card->lock (mutex): protects card->vif pointer
 *   - wiphy_lock(): required by mac80211 before calling driver ops
 *   - Lock order: wiphy_lock → card->lock
 *
 * TSF ops call might_sleep(), so we use mutexes, not spinlocks.
 * We call hw->ops->get_tsf() / hw->ops->set_tsf() directly rather
 * than drv_get_tsf() / drv_set_tsf() since those are not exported.
 * We do acquire the wiphy lock ourselves to satisfy the locking
 * requirements.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/device.h>
#include <linux/netdevice.h>
#include <linux/rtnetlink.h>
#include <linux/ptp_clock_kernel.h>
#include <net/cfg80211.h>
#include <net/mac80211.h>

/*
 * mac80211 internal header — needed for:
 *   - ieee80211_local (to get hw from wiphy_priv)
 *   - ieee80211_sub_if_data (to get vif from net_device)
 *   - IEEE80211_DEV_TO_SUB_IF macro
 *   - vif_to_sdata helper
 *   - hw_to_local helper
 *
 * Build with: make KDIR=/path/to/kernel/source
 * The Makefile adds -I$(KDIR)/net/mac80211 to CFLAGS.
 */
#include "ieee80211_i.h"

#include "tsf_ptp.h"

MODULE_LICENSE("GPL");
MODULE_AUTHOR("tsf-sync contributors");
MODULE_DESCRIPTION("Expose WiFi TSF as PTP hardware clocks");
MODULE_VERSION("0.1.0");

/* Global list of all registered cards. Protected by cards_lock. */
static LIST_HEAD(cards_list);
static DEFINE_MUTEX(cards_lock);

/* Notifier for network device events (VIF up/down). */
static struct notifier_block tsf_ptp_netdev_nb;

/* Forward declarations */
static int tsf_ptp_probe(struct ieee80211_local *local);
static void tsf_ptp_remove(struct tsf_ptp_card *card);

/* ========== Direct driver op wrappers ========== */

/*
 * We call the driver's get_tsf/set_tsf ops directly because
 * drv_get_tsf/drv_set_tsf (in driver-ops.c) are not exported symbols.
 * We replicate the essential behavior: hold wiphy_lock, check ops exist.
 */

static u64 tsf_ptp_call_get_tsf(struct tsf_ptp_card *card,
				 struct ieee80211_vif *vif)
{
	struct ieee80211_hw *hw = card->hw;
	struct ieee80211_local *local = hw_to_local(hw);

	if (!local->ops->get_tsf)
		return 0;

	return local->ops->get_tsf(hw, vif);
}

static void tsf_ptp_call_set_tsf(struct tsf_ptp_card *card,
				  struct ieee80211_vif *vif, u64 tsf)
{
	struct ieee80211_hw *hw = card->hw;
	struct ieee80211_local *local = hw_to_local(hw);

	if (!local->ops->set_tsf)
		return;

	local->ops->set_tsf(hw, vif, tsf);
}

/* ========== PTP Clock Operations ========== */

static int tsf_ptp_gettime(struct ptp_clock_info *info, struct timespec64 *ts)
{
	struct tsf_ptp_card *card = container_of(info, struct tsf_ptp_card,
						 ptp_info);
	struct ieee80211_vif *vif;
	u64 tsf_usec;

	mutex_lock(&card->lock);
	vif = card->vif;
	if (!vif) {
		mutex_unlock(&card->lock);
		return -ENODEV;
	}

	wiphy_lock(card->hw->wiphy);
	tsf_usec = tsf_ptp_call_get_tsf(card, vif);
	wiphy_unlock(card->hw->wiphy);

	mutex_unlock(&card->lock);

	*ts = ns_to_timespec64((s64)tsf_usec * NSEC_PER_USEC);
	return 0;
}

static int tsf_ptp_settime(struct ptp_clock_info *info,
			    const struct timespec64 *ts)
{
	struct tsf_ptp_card *card = container_of(info, struct tsf_ptp_card,
						 ptp_info);
	struct ieee80211_vif *vif;
	u64 tsf_usec;

	tsf_usec = div_u64(timespec64_to_ns(ts), NSEC_PER_USEC);

	mutex_lock(&card->lock);
	vif = card->vif;
	if (!vif) {
		mutex_unlock(&card->lock);
		return -ENODEV;
	}

	wiphy_lock(card->hw->wiphy);
	tsf_ptp_call_set_tsf(card, vif, tsf_usec);
	wiphy_unlock(card->hw->wiphy);

	mutex_unlock(&card->lock);

	return 0;
}

static int tsf_ptp_adjtime(struct ptp_clock_info *info, s64 delta_ns)
{
	struct tsf_ptp_card *card = container_of(info, struct tsf_ptp_card,
						 ptp_info);
	struct ieee80211_vif *vif;
	u64 tsf_usec;
	s64 delta_usec;

	mutex_lock(&card->lock);
	vif = card->vif;
	if (!vif) {
		mutex_unlock(&card->lock);
		return -ENODEV;
	}

	wiphy_lock(card->hw->wiphy);

	/* Read-modify-write: no driver implements offset_tsf. */
	tsf_usec = tsf_ptp_call_get_tsf(card, vif);
	delta_usec = div_s64(delta_ns, NSEC_PER_USEC);
	tsf_ptp_call_set_tsf(card, vif, tsf_usec + delta_usec);

	wiphy_unlock(card->hw->wiphy);
	mutex_unlock(&card->lock);

	return 0;
}

static int tsf_ptp_adjfine(struct ptp_clock_info *info, long scaled_ppm)
{
	/* WiFi cards don't have tunable oscillators.
	 * Return -EOPNOTSUPP so ptp4l falls back to time-stepping. */
	return -EOPNOTSUPP;
}

static int tsf_ptp_getcrosststamp(struct ptp_clock_info *info,
				  struct system_device_crosststamp *cts)
{
	struct tsf_ptp_card *card = container_of(info, struct tsf_ptp_card,
						 ptp_info);
	struct ieee80211_vif *vif;
	u64 tsf_usec;

	mutex_lock(&card->lock);
	vif = card->vif;
	if (!vif) {
		mutex_unlock(&card->lock);
		return -ENODEV;
	}

	wiphy_lock(card->hw->wiphy);

	/* Bracket the TSF read with system timestamps for cross-correlation. */
	cts->sys_monoraw = ktime_get_raw();
	tsf_usec = tsf_ptp_call_get_tsf(card, vif);
	cts->sys_realtime = ktime_get_real();

	wiphy_unlock(card->hw->wiphy);
	mutex_unlock(&card->lock);

	cts->device = ns_to_ktime((s64)tsf_usec * NSEC_PER_USEC);

	return 0;
}

/* ========== Phy discovery ========== */

/**
 * tsf_ptp_probe - Register a PTP clock for a mac80211 local
 * @local: The ieee80211_local to register for
 *
 * Returns 0 on success, negative errno on failure.
 */
static int tsf_ptp_probe(struct ieee80211_local *local)
{
	struct tsf_ptp_card *card;
	struct ieee80211_hw *hw = &local->hw;
	struct wiphy *wiphy = hw->wiphy;

	/* Only probe cards that have get_tsf. */
	if (!local->ops->get_tsf) {
		pr_debug("tsf-ptp: %s: no get_tsf, skipping\n",
			 wiphy_name(wiphy));
		return -EOPNOTSUPP;
	}

	/* Check we haven't already probed this wiphy. */
	mutex_lock(&cards_lock);
	{
		struct tsf_ptp_card *existing;
		list_for_each_entry(existing, &cards_list, list) {
			if (existing->hw->wiphy == wiphy) {
				mutex_unlock(&cards_lock);
				return -EEXIST;
			}
		}
	}
	mutex_unlock(&cards_lock);

	card = kzalloc(sizeof(*card), GFP_KERNEL);
	if (!card)
		return -ENOMEM;

	card->hw = hw;
	card->vif = NULL;
	mutex_init(&card->lock);
	INIT_LIST_HEAD(&card->list);

	snprintf(card->name, sizeof(card->name), "tsf-ptp-%s",
		 wiphy_name(wiphy));
	snprintf(card->phy_name, sizeof(card->phy_name), "%s",
		 wiphy_name(wiphy));

	card->ptp_info = (struct ptp_clock_info) {
		.owner		= THIS_MODULE,
		.name		= "",  /* filled below */
		.max_adj	= 0,
		.n_alarm	= 0,
		.n_ext_ts	= 0,
		.n_per_out	= 0,
		.n_pins		= 0,
		.pps		= 0,
		.gettime64	= tsf_ptp_gettime,
		.settime64	= local->ops->set_tsf ? tsf_ptp_settime : NULL,
		.adjtime	= local->ops->set_tsf ? tsf_ptp_adjtime : NULL,
		.adjfine	= tsf_ptp_adjfine,
		.getcrosststamp	= tsf_ptp_getcrosststamp,
	};
	strscpy(card->ptp_info.name, card->name, sizeof(card->ptp_info.name));

	card->ptp_clock = ptp_clock_register(&card->ptp_info,
					      wiphy_dev(wiphy));
	if (IS_ERR(card->ptp_clock)) {
		pr_err("tsf-ptp: %s: failed to register PTP clock: %ld\n",
		       card->name, PTR_ERR(card->ptp_clock));
		kfree(card);
		return PTR_ERR(card->ptp_clock);
	}

	mutex_lock(&cards_lock);
	list_add_tail(&card->list, &cards_list);
	mutex_unlock(&cards_lock);

	pr_info("tsf-ptp: registered PTP clock %s (ptp%d)%s\n",
		card->name, ptp_clock_index(card->ptp_clock),
		local->ops->set_tsf ? "" : " [read-only]");

	return 0;
}

/**
 * tsf_ptp_remove - Unregister a PTP clock and free resources
 * @card: The card to remove
 *
 * Caller must NOT hold cards_lock.
 */
static void tsf_ptp_remove(struct tsf_ptp_card *card)
{
	pr_info("tsf-ptp: unregistering PTP clock %s\n", card->name);
	ptp_clock_unregister(card->ptp_clock);
	kfree(card);
}

/* ========== VIF lifecycle tracking ========== */

/**
 * Find the tsf_ptp_card for a given wiphy.
 * Caller must hold cards_lock.
 */
static struct tsf_ptp_card *find_card_by_wiphy_locked(struct wiphy *wiphy)
{
	struct tsf_ptp_card *card;

	list_for_each_entry(card, &cards_list, list) {
		if (card->hw->wiphy == wiphy)
			return card;
	}
	return NULL;
}

/**
 * Netdevice notifier callback.
 *
 * When a wireless interface comes up, we capture its VIF pointer.
 * When it goes down, we clear it. PTP ops return -ENODEV without a VIF.
 */
static int tsf_ptp_netdev_event(struct notifier_block *nb,
				unsigned long event, void *ptr)
{
	struct net_device *dev = netdev_notifier_info_to_dev(ptr);
	struct ieee80211_sub_if_data *sdata;
	struct tsf_ptp_card *card;
	struct wiphy *wiphy;

	/* Only care about wireless devices managed by mac80211. */
	if (!dev->ieee80211_ptr)
		return NOTIFY_DONE;

	wiphy = dev->ieee80211_ptr->wiphy;
	if (!wiphy)
		return NOTIFY_DONE;

	mutex_lock(&cards_lock);
	card = find_card_by_wiphy_locked(wiphy);
	if (!card) {
		mutex_unlock(&cards_lock);
		return NOTIFY_DONE;
	}

	sdata = IEEE80211_DEV_TO_SUB_IF(dev);
	if (!sdata) {
		mutex_unlock(&cards_lock);
		return NOTIFY_DONE;
	}

	switch (event) {
	case NETDEV_UP:
		mutex_lock(&card->lock);
		if (!card->vif) {
			card->vif = &sdata->vif;
			pr_info("tsf-ptp: %s: VIF up (%s)\n",
				card->name, dev->name);
		}
		mutex_unlock(&card->lock);
		break;

	case NETDEV_DOWN:
	case NETDEV_UNREGISTER:
		mutex_lock(&card->lock);
		if (card->vif == &sdata->vif) {
			card->vif = NULL;
			pr_info("tsf-ptp: %s: VIF down (%s)\n",
				card->name, dev->name);
		}
		mutex_unlock(&card->lock);
		break;
	}

	mutex_unlock(&cards_lock);
	return NOTIFY_DONE;
}

/* ========== Discovery via net_device iteration ========== */

/*
 * We cannot use class_find("ieee80211") — it's not an exported API.
 * Instead, we iterate all net_devices to find wireless interfaces,
 * extract the wiphy, and probe each unique wiphy. This uses only
 * public kernel APIs (for_each_netdev, ieee80211_ptr, wiphy_priv).
 */

/**
 * Discover existing phys by iterating all net_devices.
 * Must be called under rtnl_lock.
 */
static int tsf_ptp_discover_from_netdevs(void)
{
	struct net_device *dev;
	struct wiphy *wiphy;
	struct ieee80211_local *local;
	int count = 0;

	for_each_netdev(&init_net, dev) {
		if (!dev->ieee80211_ptr)
			continue;

		wiphy = dev->ieee80211_ptr->wiphy;
		if (!wiphy)
			continue;

		/*
		 * wiphy_priv() returns the driver-private data area.
		 * For mac80211-based drivers, this is ieee80211_local.
		 * For cfg80211-only (FullMAC) drivers, this is something
		 * else — but those don't have get_tsf, so tsf_ptp_probe
		 * will skip them.
		 */
		local = wiphy_priv(wiphy);
		if (!local)
			continue;

		if (tsf_ptp_probe(local) == 0)
			count++;
	}

	return count;
}

/**
 * Scan for interfaces that are already up when the module loads.
 * Must be called under rtnl_lock, after discovery.
 */
static void tsf_ptp_scan_existing_vifs(void)
{
	struct net_device *dev;
	struct ieee80211_sub_if_data *sdata;
	struct tsf_ptp_card *card;
	struct wiphy *wiphy;

	for_each_netdev(&init_net, dev) {
		if (!dev->ieee80211_ptr)
			continue;

		wiphy = dev->ieee80211_ptr->wiphy;
		if (!wiphy)
			continue;

		if (!(dev->flags & IFF_UP))
			continue;

		mutex_lock(&cards_lock);
		card = find_card_by_wiphy_locked(wiphy);
		if (card) {
			sdata = IEEE80211_DEV_TO_SUB_IF(dev);
			if (sdata) {
				mutex_lock(&card->lock);
				if (!card->vif) {
					card->vif = &sdata->vif;
					pr_info("tsf-ptp: %s: found existing VIF (%s)\n",
						card->name, dev->name);
				}
				mutex_unlock(&card->lock);
			}
		}
		mutex_unlock(&cards_lock);
	}
}

/* ========== Module init/exit ========== */

static int __init tsf_ptp_init(void)
{
	int count;

	pr_info("tsf-ptp: loading module\n");

	/* Register netdev notifier for VIF lifecycle tracking.
	 * Do this before discovery so we don't miss events. */
	tsf_ptp_netdev_nb.notifier_call = tsf_ptp_netdev_event;
	register_netdevice_notifier(&tsf_ptp_netdev_nb);

	/* Discover existing phys and capture already-up VIFs.
	 * Both need rtnl_lock for safe net_device iteration. */
	rtnl_lock();
	count = tsf_ptp_discover_from_netdevs();
	tsf_ptp_scan_existing_vifs();
	rtnl_unlock();

	pr_info("tsf-ptp: registered %d PTP clock(s)\n", count);

	return 0;
}

static void __exit tsf_ptp_exit(void)
{
	struct tsf_ptp_card *card, *tmp;

	pr_info("tsf-ptp: unloading module\n");

	/* Unregister netdev notifier first to prevent new events. */
	unregister_netdevice_notifier(&tsf_ptp_netdev_nb);

	/* Unregister all PTP clocks and free resources. */
	mutex_lock(&cards_lock);
	list_for_each_entry_safe(card, tmp, &cards_list, list) {
		list_del(&card->list);
		mutex_unlock(&cards_lock);
		tsf_ptp_remove(card);
		mutex_lock(&cards_lock);
	}
	mutex_unlock(&cards_lock);

	pr_info("tsf-ptp: module unloaded\n");
}

module_init(tsf_ptp_init);
module_exit(tsf_ptp_exit);
