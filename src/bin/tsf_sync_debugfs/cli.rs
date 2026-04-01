use std::path::PathBuf;

use clap::Parser;

/// Rust port of FiWiTSF: sync WiFi TSF clocks via mac80211 debugfs.
///
/// Reads the master TSF, computes a proportional correction for each follower,
/// and writes the corrected value back — all through cached file descriptors
/// using pread/pwrite (1 syscall each) instead of open/read/close (3 each).
#[derive(Parser, Debug)]
#[command(name = "tsf-sync-debugfs", version)]
pub struct Cli {
    /// Master TSF debugfs path (e.g. /sys/kernel/debug/ieee80211/phy0/netdev:wlan0/tsf).
    #[arg(short = 'm', long = "master")]
    pub master: PathBuf,

    /// Follower TSF debugfs path(s). Repeat for multiple followers.
    #[arg(short = 'f', long = "follower", required = true)]
    pub followers: Vec<PathBuf>,

    /// CPU to pin RT threads to (optional).
    #[arg(short = 'c', long = "cpu")]
    pub cpu: Option<usize>,

    /// Sync period in milliseconds.
    #[arg(short = 'p', long = "period-ms", default_value_t = 10)]
    pub period_ms: u64,

    /// SCHED_FIFO priority (1-99).
    #[arg(short = 'P', long = "priority", default_value_t = 80)]
    pub priority: u32,

    /// Proportional gain in parts-per-million.
    #[arg(short = 'k', long = "kp-ppm", default_value_t = 1_000_000)]
    pub kp_ppm: i64,

    /// Maximum correction step in microseconds.
    #[arg(short = 's', long = "max-step-us", default_value_t = 200)]
    pub max_step_us: i64,

    /// Statistics reporting interval in seconds (0 = disabled).
    #[arg(short = 'u', long = "stats-interval", default_value_t = 0)]
    pub stats_interval: u64,

    /// RMS error warning threshold in microseconds (0 = disabled).
    #[arg(short = 'G', long = "rms-warn", default_value_t = 0)]
    pub rms_warn: u64,

    /// Enable 1D Kalman filter on the error signal.
    #[arg(short = 'K', long = "kalman")]
    pub kalman: bool,

    /// Use parallel (barrier-synchronized) mode with per-follower threads.
    #[arg(short = 'j', long = "parallel")]
    pub parallel: bool,
}
