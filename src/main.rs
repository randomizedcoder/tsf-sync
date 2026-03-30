use std::path::Path;
use std::process;

use clap::{Parser, Subcommand};

use tsf_sync::config_gen;
use tsf_sync::daemon;
use tsf_sync::discovery;

#[derive(Parser, Debug)]
#[command(name = "tsf-sync", about = "Bridge WiFi TSF into the Linux PTP subsystem")]
struct Cli {
    /// Log level (trace, debug, info, warn, error).
    #[arg(short, long, default_value = "info", global = true)]
    log_level: String,

    /// Path to a linuxptp binary (ptp4l or phc2sys). Used to locate the
    /// linuxptp install — phc2sys is derived from the same directory.
    #[arg(long, default_value = "ptp4l", global = true)]
    linuxptp_path: String,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// List WiFi cards and their PTP clock status.
    Discover,

    /// Generate ptp4l configuration for discovered topology.
    Config {
        /// Primary card phy name (e.g., "phy0") or "auto" for automatic selection.
        #[arg(short, long, default_value = "auto")]
        primary: String,

        /// Output file path (default: stdout).
        #[arg(short, long)]
        output: Option<String>,
    },

    /// Load tsf-ptp module, start ptp4l, begin monitoring.
    Start {
        /// Primary card phy name or "auto".
        #[arg(short, long, default_value = "auto")]
        primary: String,
    },

    /// Show sync health for all cards.
    Status,

    /// Stop ptp4l, unload tsf-ptp module.
    Stop,

    /// Run as a long-lived daemon with hot-plug handling.
    Daemon {
        /// Primary card phy name or "auto".
        #[arg(short, long, default_value = "auto")]
        primary: String,

        /// Health check interval.
        #[arg(short, long, default_value = "10s")]
        interval: String,
    },
}

const SYSFS_IEEE80211: &str = "/sys/class/ieee80211";

fn main() {
    let cli = Cli::parse();

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_new(&cli.log_level)
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let result = run(cli.command, &cli.linuxptp_path);

    if let Err(e) = result {
        tracing::error!("{}", e);
        process::exit(1);
    }
}

fn run(command: Command, linuxptp_bin: &str) -> Result<(), Box<dyn std::error::Error>> {
    match command {
        Command::Discover => {
            let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211))?;
            if cards.is_empty() {
                println!("No WiFi cards found.");
            } else {
                print!("{}", discovery::format_table(&cards));
            }
        }

        Command::Config { primary, output } => {
            let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211))?;
            let config = config_gen::generate_config(&cards, &primary)?;

            match output {
                Some(path) => {
                    std::fs::write(&path, &config)?;
                    tracing::info!(path = %path, "wrote ptp4l config");
                }
                None => {
                    print!("{}", config);
                }
            }
        }

        Command::Start { primary } => {
            let _processes = daemon::start(&primary, linuxptp_bin)?;
            tracing::info!("tsf-sync started. Press Ctrl-C to stop.");
            loop {
                std::thread::sleep(std::time::Duration::from_secs(3600));
            }
        }

        Command::Status => {
            daemon::status()?;
        }

        Command::Stop => {
            daemon::stop(&mut Vec::new())?;
        }

        Command::Daemon { primary, interval } => {
            let interval = daemon::parse_interval(&interval)
                .map_err(|e| format!("invalid interval: {}", e))?;
            daemon::run_daemon(&primary, interval, linuxptp_bin)?;
        }
    }

    Ok(())
}
