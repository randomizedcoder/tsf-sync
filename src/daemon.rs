use std::path::{Path, PathBuf};
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
    #[error("ptp4l failed: {0}")]
    Ptp4l(#[from] ptp4l::Ptp4lError),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}

const SYSFS_IEEE80211: &str = "/sys/class/ieee80211";
const DEFAULT_CONFIG_PATH: &str = "/tmp/tsf-sync-ptp4l.conf";
const DEFAULT_UDS_PATH: &str = "/var/run/ptp4l";

/// Start the full tsf-sync stack: discover → load module → config → ptp4l.
pub fn start(primary: &str) -> Result<ptp4l::Ptp4lProcess, DaemonError> {
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

        // Re-discover after loading module.
        std::thread::sleep(Duration::from_millis(500));
    }

    let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211))?;

    // 3. Generate config.
    let config = config_gen::generate_config(&cards, primary)?;
    let config_path = PathBuf::from(DEFAULT_CONFIG_PATH);
    std::fs::write(&config_path, &config)?;
    tracing::info!(path = %config_path.display(), "wrote ptp4l config");

    // 4. Start ptp4l.
    let process = ptp4l::Ptp4lProcess::start(&config_path)?;

    Ok(process)
}

/// Stop the tsf-sync stack: stop ptp4l → unload module.
pub fn stop(process: &mut Option<ptp4l::Ptp4lProcess>) -> Result<(), DaemonError> {
    if let Some(p) = process {
        p.stop()?;
    }
    *process = None;

    module_loader::unload_tsf_ptp()?;

    // Clean up config file.
    let _ = std::fs::remove_file(DEFAULT_CONFIG_PATH);

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
) -> Result<(), DaemonError> {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();

    // Install SIGTERM/SIGINT handler.
    ctrlc_handler(move || {
        r.store(false, Ordering::SeqCst);
    });

    let mut process = start(primary)?;
    tracing::info!("daemon started, monitoring every {:?}", interval);

    while running.load(Ordering::SeqCst) {
        std::thread::sleep(interval);

        if !running.load(Ordering::SeqCst) {
            break;
        }

        // Check if ptp4l is still running.
        if !process.is_running() {
            tracing::warn!("ptp4l exited unexpectedly, restarting");
            let config_path = PathBuf::from(DEFAULT_CONFIG_PATH);
            process = ptp4l::Ptp4lProcess::start(&config_path)?;
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
                tracing::warn!("health check failed: {}", e);
            }
        }
    }

    tracing::info!("shutting down");
    process.stop()?;
    module_loader::unload_tsf_ptp()?;
    let _ = std::fs::remove_file(DEFAULT_CONFIG_PATH);

    Ok(())
}

/// Install a handler for SIGTERM/SIGINT. Best-effort — if it fails,
/// we'll just rely on the default signal behavior.
fn ctrlc_handler<F: Fn() + Send + 'static>(handler: F) {
    #[cfg(unix)]
    {
        use std::sync::Once;
        static ONCE: Once = Once::new();
        ONCE.call_once(move || {
            // Use a simple signal handler via unsafe libc.
            // We store the handler in a static and call it from the C handler.
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
        // Default: try as seconds.
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
