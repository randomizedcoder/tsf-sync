//! Mode C: io_uring-based sync loop via /dev/tsf_sync char device.
//!
//! Reads all card TSF snapshots in a single read, computes offsets,
//! and writes adjustments back in a single write. Reduces syscall
//! overhead compared to Mode A (phc2sys) while keeping the algorithm
//! in userspace for debuggability.

use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::io::AsRawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use io_uring::IoUring;
use io_uring::opcode;
use io_uring::types::Fd;

use crate::sync_mode::{TsfAdjustment, TsfSnapshot};

const DEV_PATH: &str = "/dev/tsf_sync";
const MAX_CARDS: usize = 128;

/// Statistics from a single sync cycle.
#[derive(Debug, Default)]
pub struct SyncStats {
    pub cards_read: u32,
    pub adjustments_applied: u32,
    pub adjustments_skipped: u32,
    pub max_offset_ns: i64,
}

/// io_uring-based synchronizer for Mode C.
pub struct IoUringSyncer {
    ring: IoUring,
    fd: File,
    primary_index: u32,
    threshold_ns: i64,
    interval: Duration,
}

impl IoUringSyncer {
    /// Create a new syncer.
    ///
    /// `primary_index` is the card index of the primary clock (from discovery).
    /// `threshold_ns` mirrors the kernel's adjtime_threshold_ns.
    pub fn new(
        primary_index: u32,
        threshold_ns: i64,
        interval: Duration,
    ) -> std::io::Result<Self> {
        let fd = OpenOptions::new()
            .read(true)
            .write(true)
            .open(DEV_PATH)?;

        let ring = IoUring::new(8)?;

        Ok(Self {
            ring,
            fd,
            primary_index,
            threshold_ns,
            interval,
        })
    }

    /// Perform one sync cycle: read snapshots, compute offsets, write adjustments.
    pub fn sync_once(&mut self) -> std::io::Result<SyncStats> {
        let mut stats = SyncStats::default();

        // Read all card snapshots via io_uring.
        let snapshots = self.read_snapshots()?;
        stats.cards_read = snapshots.len() as u32;

        if snapshots.is_empty() {
            return Ok(stats);
        }

        // Find primary TSF.
        let primary_tsf = match snapshots.iter().find(|s| s.card_index == self.primary_index) {
            Some(s) => s.tsf_ns,
            None => {
                tracing::warn!(index = self.primary_index, "primary card not found in snapshots");
                return Ok(stats);
            }
        };

        // Compute adjustments for secondaries.
        let mut adjustments = Vec::new();
        for snap in &snapshots {
            if snap.card_index == self.primary_index {
                continue;
            }

            let delta = primary_tsf - snap.tsf_ns;
            let abs_delta = if delta < 0 { -delta } else { delta };

            if abs_delta > stats.max_offset_ns {
                stats.max_offset_ns = abs_delta;
            }

            if abs_delta > self.threshold_ns {
                adjustments.push(TsfAdjustment {
                    card_index: snap.card_index,
                    delta_ns: delta,
                });
                stats.adjustments_applied += 1;
            } else {
                stats.adjustments_skipped += 1;
            }
        }

        // Write adjustments via io_uring.
        if !adjustments.is_empty() {
            self.write_adjustments(&adjustments)?;
        }

        Ok(stats)
    }

    /// Read all card snapshots from /dev/tsf_sync using io_uring.
    fn read_snapshots(&mut self) -> std::io::Result<Vec<TsfSnapshot>> {
        let snapshot_size = std::mem::size_of::<TsfSnapshot>();
        let mut buf = vec![0u8; snapshot_size * MAX_CARDS];

        let read_e = opcode::Read::new(
            Fd(self.fd.as_raw_fd()),
            buf.as_mut_ptr(),
            buf.len() as u32,
        )
        .build()
        .user_data(0x01);

        unsafe {
            self.ring.submission().push(&read_e)
                .map_err(|_| std::io::Error::other("io_uring submission full"))?;
        }

        self.ring.submit_and_wait(1)?;

        let cqe = self.ring.completion().next()
            .ok_or_else(|| std::io::Error::other("no io_uring completion"))?;

        let bytes_read = cqe.result();
        if bytes_read < 0 {
            return Err(std::io::Error::from_raw_os_error(-bytes_read));
        }

        let bytes_read = bytes_read as usize;
        let count = bytes_read / snapshot_size;

        let mut snapshots = Vec::with_capacity(count);
        for i in 0..count {
            let offset = i * snapshot_size;
            let snap: TsfSnapshot = unsafe {
                std::ptr::read_unaligned(buf[offset..].as_ptr() as *const TsfSnapshot)
            };
            snapshots.push(snap);
        }

        Ok(snapshots)
    }

    /// Write adjustments to /dev/tsf_sync using io_uring.
    fn write_adjustments(&mut self, adjustments: &[TsfAdjustment]) -> std::io::Result<()> {
        let adj_size = std::mem::size_of::<TsfAdjustment>();
        let total = adj_size * adjustments.len();
        let buf: Vec<u8> = adjustments.iter().flat_map(|a| {
            let bytes: [u8; std::mem::size_of::<TsfAdjustment>()] = unsafe {
                std::mem::transmute_copy(a)
            };
            bytes.to_vec()
        }).collect();

        let write_e = opcode::Write::new(
            Fd(self.fd.as_raw_fd()),
            buf.as_ptr(),
            total as u32,
        )
        .build()
        .user_data(0x02);

        unsafe {
            self.ring.submission().push(&write_e)
                .map_err(|_| std::io::Error::other("io_uring submission full"))?;
        }

        self.ring.submit_and_wait(1)?;

        let cqe = self.ring.completion().next()
            .ok_or_else(|| std::io::Error::other("no io_uring completion"))?;

        let result = cqe.result();
        if result < 0 {
            return Err(std::io::Error::from_raw_os_error(-result));
        }

        Ok(())
    }

    /// Run the sync loop until `running` is set to false.
    pub fn run(mut self, running: Arc<AtomicBool>) {
        tracing::info!(
            primary = self.primary_index,
            threshold_ns = self.threshold_ns,
            interval_ms = self.interval.as_millis(),
            "io_uring sync loop started"
        );

        while running.load(Ordering::SeqCst) {
            match self.sync_once() {
                Ok(stats) => {
                    if stats.cards_read > 0 {
                        tracing::debug!(
                            cards = stats.cards_read,
                            applied = stats.adjustments_applied,
                            skipped = stats.adjustments_skipped,
                            max_offset_ns = stats.max_offset_ns,
                            "sync cycle"
                        );
                    }
                }
                Err(e) => {
                    tracing::warn!("io_uring sync error: {}", e);
                }
            }

            std::thread::sleep(self.interval);
        }

        tracing::info!("io_uring sync loop stopped");
    }
}

/// Discover the primary card index by matching the phy name against
/// TSF snapshots from /dev/tsf_sync.
pub fn find_primary_index(primary_phy: &str) -> std::io::Result<u32> {
    let snapshot_size = std::mem::size_of::<TsfSnapshot>();
    let mut buf = vec![0u8; snapshot_size * MAX_CARDS];

    let mut fd = OpenOptions::new().read(true).open(DEV_PATH)?;
    let bytes_read = fd.read(&mut buf)?;

    let count = bytes_read / snapshot_size;
    for i in 0..count {
        let offset = i * snapshot_size;
        let snap: TsfSnapshot = unsafe {
            std::ptr::read_unaligned(buf[offset..].as_ptr() as *const TsfSnapshot)
        };

        let name_len = snap.phy_name_len as usize;
        let name = std::str::from_utf8(&snap.phy_name[..name_len.min(32)])
            .unwrap_or("")
            .trim_end_matches('\0');

        if name == primary_phy {
            return Ok(snap.card_index);
        }
    }

    Err(std::io::Error::new(
        std::io::ErrorKind::NotFound,
        format!("primary phy '{}' not found in /dev/tsf_sync", primary_phy),
    ))
}
