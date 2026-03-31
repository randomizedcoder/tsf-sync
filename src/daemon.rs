use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use thiserror::Error;

use crate::config_gen;
use crate::discovery;
use crate::health;
use crate::module_loader;
use crate::ptp4l;
use crate::sync_mode::SyncMode;

#[derive(Debug, Error)]
pub enum DaemonError {
    #[error("discovery failed: {0}")]
    Discovery(#[from] discovery::DiscoveryError),
    #[error("config generation failed: {0}")]
    Config(#[from] config_gen::ConfigError),
    #[error("module loading failed: {0}")]
    Module(#[from] module_loader::ModuleError),
    #[error("sync process failed: {0}")]
    Sync(#[from] ptp4l::SyncError),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}

const SYSFS_IEEE80211: &str = "/sys/class/ieee80211";
const DEFAULT_UDS_PATH: &str = "/var/run/ptp4l";

/// Active sync state — varies by mode.
pub enum SyncState {
    /// Mode A: phc2sys processes (one per secondary clock).
    Phc2sys(Vec<ptp4l::SyncProcess>),
    /// Mode B: kernel handles sync loop via delayed_work. Nothing to manage.
    Kernel,
    /// Mode C: io_uring sync thread.
    #[cfg(feature = "iouring")]
    IoUring {
        handle: std::thread::JoinHandle<()>,
        running: Arc<AtomicBool>,
    },
}

/// Start the full tsf-sync stack: discover → load module → start sync.
///
/// Returns a `SyncState` representing the active sync mechanism.
pub fn start(
    primary: &str,
    linuxptp_bin: &str,
    adjtime_threshold_ns: u64,
    sync_mode: SyncMode,
    sync_interval_ms: u32,
) -> Result<SyncState, DaemonError> {
    // 1. Initial discovery.
    let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211))?;
    tracing::info!(count = cards.len(), "discovered WiFi cards");

    // 2. Check if any cards need the tsf-ptp module.
    let needs_module = cards.iter().any(|c| {
        c.can_set_tsf && c.ptp_clock.is_none() && c.ptp_source == discovery::PtpSource::None
    });

    let primary_for_module = if primary != "auto" { Some(primary) } else { None };

    if needs_module {
        tracing::info!("loading tsf-ptp kernel module (mode: {})", sync_mode);
        module_loader::load_tsf_ptp(
            adjtime_threshold_ns,
            sync_mode,
            primary_for_module,
            Some(sync_interval_ms),
        )?;
        std::thread::sleep(Duration::from_millis(500));
    }

    let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211))?;

    // 3. Select primary and secondaries.
    let ptp_cards: Vec<&discovery::WifiCard> =
        cards.iter().filter(|c| c.ptp_clock.is_some()).collect();

    if ptp_cards.len() < 2 {
        return Err(config_gen::ConfigError::OnlyOneClock.into());
    }

    let primary_card = config_gen::select_primary(&ptp_cards, primary)?;
    let primary_clock = primary_card.ptp_clock.as_ref().unwrap();

    tracing::info!(
        primary = %primary_card.phy,
        clock = %primary_clock.display(),
        mode = %sync_mode,
        "selected primary clock"
    );

    match sync_mode {
        SyncMode::Ptp => {
            // Mode A: start phc2sys for each secondary.
            let phc2sys_bin = ptp4l::phc2sys_bin_from(linuxptp_bin);
            let phc2sys_str = phc2sys_bin.to_string_lossy();
            let mut processes = Vec::new();

            for card in &ptp_cards {
                if card.phy == primary_card.phy {
                    continue;
                }
                let secondary_clock = card.ptp_clock.as_ref().unwrap();
                tracing::info!(
                    secondary = %card.phy,
                    clock = %secondary_clock.display(),
                    "syncing to primary"
                );

                let proc = ptp4l::start_phc2sys(primary_clock, secondary_clock, &phc2sys_str)?;
                processes.push(proc);
            }

            tracing::info!(count = processes.len(), "started phc2sys processes");
            Ok(SyncState::Phc2sys(processes))
        }

        SyncMode::Kernel => {
            // Mode B: kernel handles everything via delayed_work.
            tracing::info!("kernel sync loop active (check sysfs for status)");
            Ok(SyncState::Kernel)
        }

        #[cfg(feature = "iouring")]
        SyncMode::Iouring => {
            // Mode C: spawn io_uring sync thread.
            let primary_index = crate::iouring_sync::find_primary_index(&primary_card.phy)?;
            let running = Arc::new(AtomicBool::new(true));
            let r = running.clone();

            let threshold = adjtime_threshold_ns as i64;
            let interval = Duration::from_millis(sync_interval_ms as u64);

            let handle = std::thread::spawn(move || {
                match crate::iouring_sync::IoUringSyncer::new(
                    primary_index, threshold, interval,
                ) {
                    Ok(syncer) => syncer.run(r),
                    Err(e) => tracing::error!("failed to create io_uring syncer: {}", e),
                }
            });

            tracing::info!("io_uring sync thread started");
            Ok(SyncState::IoUring { handle, running })
        }

        #[cfg(not(feature = "iouring"))]
        SyncMode::Iouring => {
            Err(DaemonError::Io(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "iouring sync mode requires --features iouring",
            )))
        }
    }
}

/// Stop the tsf-sync stack: stop sync processes → unload module.
pub fn stop(state: &mut SyncState) -> Result<(), DaemonError> {
    match state {
        SyncState::Phc2sys(processes) => {
            for p in processes.iter_mut() {
                let _ = p.stop();
            }
            processes.clear();
        }
        SyncState::Kernel => {
            // Kernel sync stops when the module is unloaded.
        }
        #[cfg(feature = "iouring")]
        SyncState::IoUring { running, .. } => {
            running.store(false, Ordering::SeqCst);
            // Thread will exit on next loop iteration.
        }
    }

    module_loader::unload_tsf_ptp()?;
    Ok(())
}

/// Query and display health status.
pub fn status() -> Result<(), DaemonError> {
    // Check active sync mode from sysfs.
    let active_mode = discovery::detect_active_sync_mode();

    match active_mode {
        Some(SyncMode::Kernel) | Some(SyncMode::Iouring) => {
            // Modes B/C: show kernel sync stats from sysfs.
            match health::query_kernel_sync_health() {
                Ok(kstatus) => {
                    println!("Sync mode: {}", active_mode.unwrap());
                    println!("  sync_count:        {}", kstatus.sync_count);
                    println!("  sync_error_count:  {}", kstatus.sync_error_count);
                    println!("  adjtime_skip:      {}", kstatus.adjtime_skip_count);
                    println!("  adjtime_apply:     {}", kstatus.adjtime_apply_count);
                }
                Err(e) => {
                    println!("Could not read kernel sync status: {}", e);
                }
            }
        }
        _ => {
            // Mode A or unknown: use pmc.
            match health::query_health(DEFAULT_UDS_PATH) {
                Ok(statuses) => {
                    if statuses.is_empty() {
                        println!("No clock statuses reported. Is ptp4l running?");
                    } else {
                        print!("{}", health::format_status_table(&statuses));
                    }
                }
                Err(e) => {
                    tracing::warn!("health query failed: {}", e);
                    println!("Could not query ptp4l status: {}", e);
                }
            }
        }
    }

    // Always show adjtime counters if available.
    if let (Some(skip), Some(apply)) = (
        read_sysfs_counter("adjtime_skip_count"),
        read_sysfs_counter("adjtime_apply_count"),
    ) {
        println!("  adjtime: {} applied, {} skipped", apply, skip);
    }

    Ok(())
}

/// Read a sysfs parameter from the tsf_ptp module.
fn read_sysfs_counter(name: &str) -> Option<i64> {
    std::fs::read_to_string(format!("/sys/module/tsf_ptp/parameters/{}", name))
        .ok()
        .and_then(|s| s.trim().parse().ok())
}

/// Run the daemon loop: start stack, monitor, handle signals.
pub fn run_daemon(
    primary: &str,
    interval: Duration,
    linuxptp_bin: &str,
    adjtime_threshold_ns: u64,
    sync_mode: SyncMode,
    sync_interval_ms: u32,
) -> Result<(), DaemonError> {
    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();

    ctrlc_handler(move || {
        r.store(false, Ordering::SeqCst);
    });

    let mut state = start(primary, linuxptp_bin, adjtime_threshold_ns, sync_mode, sync_interval_ms)?;
    tracing::info!("daemon started (mode: {}), monitoring every {:?}", sync_mode, interval);

    while running.load(Ordering::SeqCst) {
        std::thread::sleep(interval);

        if !running.load(Ordering::SeqCst) {
            break;
        }

        // Mode-specific monitoring.
        match &mut state {
            SyncState::Phc2sys(processes) => {
                // Check if any phc2sys processes crashed.
                for proc in processes.iter_mut() {
                    if !proc.is_running() {
                        tracing::warn!("phc2sys process exited, will restart on next cycle");
                    }
                }

                // Log health via pmc.
                match health::query_health(DEFAULT_UDS_PATH) {
                    Ok(statuses) => {
                        for s in &statuses {
                            tracing::info!(
                                port = %s.port,
                                state = %s.port_state,
                                health = %s.health,
                                "clock status"
                            );
                        }
                    }
                    Err(e) => {
                        tracing::debug!("health check via pmc not available: {}", e);
                    }
                }
            }

            SyncState::Kernel => {
                // Log kernel sync stats from sysfs.
                if let Ok(kstatus) = health::query_kernel_sync_health() {
                    tracing::info!(
                        sync_count = kstatus.sync_count,
                        errors = kstatus.sync_error_count,
                        "kernel sync status"
                    );
                }
            }

            #[cfg(feature = "iouring")]
            SyncState::IoUring { handle, .. } => {
                if handle.is_finished() {
                    tracing::warn!("io_uring sync thread exited unexpectedly");
                }
            }
        }

        // Log adjtime threshold counters (common to all modes).
        if let (Some(skip), Some(apply)) = (
            read_sysfs_counter("adjtime_skip_count"),
            read_sysfs_counter("adjtime_apply_count"),
        ) {
            tracing::info!(
                skipped = skip,
                applied = apply,
                "adjtime threshold stats"
            );
        }
    }

    tracing::info!("shutting down");
    stop(&mut state)?;
    Ok(())
}

/// Install a handler for SIGTERM/SIGINT.
fn ctrlc_handler<F: Fn() + Send + 'static>(handler: F) {
    #[cfg(unix)]
    {
        use std::sync::Once;
        static ONCE: Once = Once::new();
        ONCE.call_once(move || {
            unsafe {
                HANDLER = Some(Box::new(handler));
                libc::signal(libc::SIGTERM, signal_handler as *const () as libc::sighandler_t);
                libc::signal(libc::SIGINT, signal_handler as *const () as libc::sighandler_t);
            }
        });
    }
}

#[cfg(unix)]
static mut HANDLER: Option<Box<dyn Fn() + Send>> = None;

#[cfg(unix)]
extern "C" fn signal_handler(_: libc::c_int) {
    unsafe {
        if let Some(ref handler) = HANDLER {
            handler();
        }
    }
}

/// Parse a duration string like "10s", "5m", "100ms".
pub fn parse_interval(s: &str) -> Result<Duration, String> {
    let s = s.trim();
    if let Some(rest) = s.strip_suffix("ms") {
        rest.parse::<u64>()
            .map(Duration::from_millis)
            .map_err(|e| e.to_string())
    } else if let Some(rest) = s.strip_suffix('s') {
        rest.parse::<u64>()
            .map(Duration::from_secs)
            .map_err(|e| e.to_string())
    } else if let Some(rest) = s.strip_suffix('m') {
        rest.parse::<u64>()
            .map(|m| Duration::from_secs(m * 60))
            .map_err(|e| e.to_string())
    } else {
        s.parse::<u64>()
            .map(Duration::from_secs)
            .map_err(|e| format!("invalid interval '{}': {}", s, e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_interval() {
        assert_eq!(parse_interval("10s").unwrap(), Duration::from_secs(10));
        assert_eq!(parse_interval("5m").unwrap(), Duration::from_secs(300));
        assert_eq!(parse_interval("100ms").unwrap(), Duration::from_millis(100));
        assert_eq!(parse_interval("30").unwrap(), Duration::from_secs(30));
    }

    #[test]
    fn test_parse_interval_invalid() {
        assert!(parse_interval("abc").is_err());
        assert!(parse_interval("").is_err());
    }
}
