/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef TSF_PTP_UAPI_H
#define TSF_PTP_UAPI_H

#include <linux/types.h>

/**
 * struct tsf_snapshot - Per-card TSF reading returned by /dev/tsf_sync read.
 * @card_index:		Index of the card in the cards list.
 * @phy_name_len:	Length of the phy name string.
 * @phy_name:		PHY name (e.g., "phy0"), NUL-padded.
 * @tsf_ns:		TSF value in nanoseconds.
 * @mono_ns:		CLOCK_MONOTONIC timestamp when TSF was read, in ns.
 */
struct tsf_snapshot {
	__u32	card_index;
	__u32	phy_name_len;
	__u8	phy_name[32];
	__s64	tsf_ns;
	__s64	mono_ns;
} __attribute__((packed));

/**
 * struct tsf_adjustment - Per-card TSF correction written to /dev/tsf_sync.
 * @card_index:		Index of the card to adjust.
 * @delta_ns:		Offset to apply in nanoseconds.
 */
struct tsf_adjustment {
	__u32	card_index;
	__s64	delta_ns;
} __attribute__((packed));

#endif /* TSF_PTP_UAPI_H */
