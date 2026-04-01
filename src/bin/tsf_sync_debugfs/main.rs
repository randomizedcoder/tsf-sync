mod asm;
mod cli;
mod control;
mod debugfs;
mod rt;
mod signal;
mod stats;
mod threading;

use std::path::Path;
use std::process;

use clap::Parser;
use tracing_subscriber::EnvFilter;

use cli::Cli;
use control::Controller;
use debugfs::TsfFile;

fn main() {
    let args = Cli::parse();

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    // Verify debugfs is accessible.
    if !Path::new("/sys/kernel/debug").exists() {
        tracing::error!("debugfs not mounted at /sys/kernel/debug");
        process::exit(1);
    }

    // Open master TSF file.
    let master = match TsfFile::open(&args.master) {
        Ok(f) => f,
        Err(e) => {
            tracing::error!(path = %args.master.display(), "failed to open master: {e}");
            process::exit(1);
        }
    };

    // Verify we can read the master.
    match master.read_tsf() {
        Ok(v) => tracing::info!(tsf = v, path = %args.master.display(), "master TSF"),
        Err(e) => {
            tracing::error!("failed to read master TSF: {e}");
            process::exit(1);
        }
    }

    // Open follower TSF files.
    let mut followers = Vec::with_capacity(args.followers.len());
    for path in &args.followers {
        match TsfFile::open(path) {
            Ok(f) => followers.push(f),
            Err(e) => {
                tracing::error!(path = %path.display(), "failed to open follower: {e}");
                process::exit(1);
            }
        }
    }

    // Build one controller per follower.
    let controllers: Vec<_> = (0..followers.len())
        .map(|_| Controller::new(args.kp_ppm, args.max_step_us, args.kalman))
        .collect();

    // Setup RT scheduling (must happen before spawning threads so they inherit).
    if let Err(e) = rt::setup_rt(args.priority, args.cpu) {
        tracing::warn!("RT setup failed (need root/CAP_SYS_NICE): {e}");
    }

    signal::install_handler();

    let period_ns = args.period_ms as i64 * 1_000_000;
    let stats_interval_cycles = if args.stats_interval > 0 {
        (args.stats_interval * 1000) / args.period_ms
    } else {
        0
    };

    tracing::info!(
        followers = followers.len(),
        period_ms = args.period_ms,
        priority = args.priority,
        kp_ppm = args.kp_ppm,
        max_step_us = args.max_step_us,
        kalman = args.kalman,
        parallel = args.parallel,
        "starting tsf-sync-debugfs"
    );

    if args.parallel {
        threading::run_parallel(
            master,
            followers,
            controllers,
            period_ns,
            stats_interval_cycles,
            args.rms_warn,
        );
    } else {
        threading::run_single(
            master,
            followers,
            controllers,
            period_ns,
            stats_interval_cycles,
            args.rms_warn,
        );
    }
}
