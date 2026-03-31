/// Synchronization mode selection.
///
/// Three modes offer different points on the simplicity/performance tradeoff:
/// - **Ptp**: Default. Uses phc2sys in userspace. Maximum ecosystem reuse.
/// - **Kernel**: In-kernel delayed_work sync loop. No context switch. For sub-µs targets.
/// - **Iouring**: Userspace algorithm via io_uring and /dev/tsf_sync char device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum SyncMode {
    /// Mode A: PTP + phc2sys (default). Userspace sync via linuxptp.
    Ptp,
    /// Mode B: Kernel sync loop via delayed_work. Lowest latency.
    Kernel,
    /// Mode C: io_uring-based userspace sync via /dev/tsf_sync char device.
    Iouring,
}

impl SyncMode {
    /// Returns the integer value used as the kernel module parameter.
    pub fn as_kernel_param(self) -> u32 {
        match self {
            SyncMode::Ptp => 0,
            SyncMode::Kernel => 1,
            SyncMode::Iouring => 2,
        }
    }
}

/// UAPI struct matching kernel's `struct tsf_snapshot` from tsf_ptp_uapi.h.
/// Returned by reading /dev/tsf_sync (Mode C).
#[repr(C, packed)]
#[derive(Debug, Clone, Copy)]
pub struct TsfSnapshot {
    pub card_index: u32,
    pub phy_name_len: u32,
    pub phy_name: [u8; 32],
    pub tsf_ns: i64,
    pub mono_ns: i64,
}

/// UAPI struct matching kernel's `struct tsf_adjustment` from tsf_ptp_uapi.h.
/// Written to /dev/tsf_sync (Mode C).
#[repr(C, packed)]
#[derive(Debug, Clone, Copy)]
pub struct TsfAdjustment {
    pub card_index: u32,
    pub delta_ns: i64,
}

impl std::fmt::Display for SyncMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SyncMode::Ptp => write!(f, "ptp"),
            SyncMode::Kernel => write!(f, "kernel"),
            SyncMode::Iouring => write!(f, "iouring"),
        }
    }
}
