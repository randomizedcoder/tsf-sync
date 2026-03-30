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

    let result = run(cli.command);

    if let Err(e) = result {
        tracing::error!("{}", e);
        process::exit(1);
    }
}

fn run(command: Command) -> Result<(), Box<dyn std::error::Error>> {
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
            let _process = daemon::start(&primary)?;
            tracing::info!("tsf-sync started. Use 'tsf-sync stop' to shut down.");
            // In non-daemon mode, just keep running until interrupted.
            // The ptp4l process will be stopped on Drop.
            loop {
                std::thread::sleep(std::time::Duration::from_secs(3600));
            }
        }

        Command::Status => {
            daemon::status()?;
        }

        Command::Stop => {
            daemon::stop(&mut None)?;
        }

        Command::Daemon { primary, interval } => {
            let interval = daemon::parse_interval(&interval)
                .map_err(|e| format!("invalid interval: {}", e))?;
            daemon::run_daemon(&primary, interval)?;
        }
    }

    Ok(())
}
