use std::path::Path;
use std::time::Duration;

use thiserror::Error;

use crate::config_gen;
use crate::discovery;
use crate::health;
use crate::module_loader;
use crate::ptp4l;

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

/// Start the full tsf-sync stack: discover → load module → spawn phc2sys.
///
/// Returns a list of phc2sys processes (one per secondary clock).
pub fn start(primary: &str, linuxptp_bin: &str) -> Result<Vec<ptp4l::SyncProcess>, DaemonError> {
    // 1. Initial discovery.
    let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211))?;
    tracing::info!(count = cards.len(), "discovered WiFi cards");

    // 2. Check if any cards need the tsf-ptp module.
    let needs_module = cards.iter().any(|c| {
        c.can_set_tsf && c.ptp_clock.is_none() && c.ptp_source == discovery::PtpSource::None
    });

    if needs_module {
        tracing::info!("loading tsf-ptp kernel module");
        module_loader::load_tsf_ptp()?;
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
        "selected primary clock"
    );

    // 4. Start phc2sys for each secondary.
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

    tracing::info!(
        count = processes.len(),
        "started phc2sys processes for local clock sync"
    );

    Ok(processes)
}

/// Stop the tsf-sync stack: stop all sync processes → unload module.
pub fn stop(processes: &mut Vec<ptp4l::SyncProcess>) -> Result<(), DaemonError> {
    for p in processes.iter_mut() {
        let _ = p.stop();
    }
    processes.clear();

    module_loader::unload_tsf_ptp()?;
    Ok(())
}

/// Query and display health status.
pub fn status() -> Result<(), DaemonError> {
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
    Ok(())
}

/// Run the daemon loop: start stack, monitor, handle signals.
pub fn run_daemon(
    primary: &str,
    interval: Duration,
    linuxptp_bin: &str,
) -> Result<(), DaemonError> {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();

    ctrlc_handler(move || {
        r.store(false, Ordering::SeqCst);
    });

    let mut processes = start(primary, linuxptp_bin)?;
    tracing::info!("daemon started, monitoring every {:?}", interval);

    while running.load(Ordering::SeqCst) {
        std::thread::sleep(interval);

        if !running.load(Ordering::SeqCst) {
            break;
        }

        // Check if any phc2sys processes crashed.
        for proc in &mut processes {
            if !proc.is_running() {
                tracing::warn!("phc2sys process exited, will restart on next cycle");
                // TODO: restart individual failed processes
            }
        }

        // Log health status.
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

    tracing::info!("shutting down");
    stop(&mut processes)?;
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
