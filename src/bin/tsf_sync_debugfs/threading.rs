use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Barrier};

use crate::control::Controller;
use crate::debugfs::TsfFile;
use crate::rt;
use crate::signal::RUNNING;
use crate::stats::WelfordStats;

/// Correct a single follower's TSF based on the master value.
///
/// Reads follower TSF, computes proportional correction, writes corrected value.
/// Returns `Some((step, raw_err))` on success, `None` if the follower read failed.
#[inline(always)]
fn correct_follower(
    follower: &TsfFile,
    controller: &mut Controller,
    master_tsf: u64,
) -> Option<(i64, i64)> {
    let follower_tsf = follower.read_tsf().ok()?;
    let (step, err) = controller.apply(master_tsf, follower_tsf);
    let new_tsf = (follower_tsf as i64 + step) as u64;
    let _ = follower.write_tsf(new_tsf);
    Some((step, err))
}

/// Check if it's time to report stats, and warn if RMS exceeds threshold.
fn check_stats(
    stats: &mut WelfordStats,
    cycle: u64,
    stats_interval_cycles: u64,
    rms_warn_us: u64,
    label: &str,
) {
    if stats_interval_cycles > 0 && cycle % stats_interval_cycles == 0 {
        let rms = stats.print_and_reset(label);
        if rms_warn_us > 0 && rms > rms_warn_us as f64 {
            tracing::warn!(
                rms_us = rms as u64,
                threshold = rms_warn_us,
                "RMS above threshold"
            );
        }
    }
}

/// Run the single-threaded sync loop (round-robin over followers).
pub fn run_single(
    master: TsfFile,
    followers: Vec<TsfFile>,
    mut controllers: Vec<Controller>,
    period_ns: i64,
    stats_interval_cycles: u64,
    rms_warn_us: u64,
) {
    let mut deadline = rt::now_monotonic();
    let mut stats = WelfordStats::new();
    let mut cycle: u64 = 0;

    tracing::info!(
        followers = followers.len(),
        period_ms = period_ns / 1_000_000,
        "single-threaded sync loop started"
    );

    while RUNNING.load(Ordering::SeqCst) {
        let master_tsf = match master.read_tsf() {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("master read failed: {e}");
                rt::advance_deadline(&mut deadline, period_ns);
                rt::sleep_until(&deadline);
                continue;
            }
        };

        for (i, follower) in followers.iter().enumerate() {
            match correct_follower(follower, &mut controllers[i], master_tsf) {
                Some((step, err)) => stats.update(err, step),
                None => tracing::warn!(follower = i, "follower correction failed"),
            }
        }

        cycle += 1;
        check_stats(
            &mut stats,
            cycle,
            stats_interval_cycles,
            rms_warn_us,
            "sync",
        );

        rt::advance_deadline(&mut deadline, period_ns);
        rt::sleep_until(&deadline);
    }

    stats.print_and_reset("final");
    tracing::info!("sync loop stopped");
}

/// Per-follower worker state for parallel mode.
struct Worker {
    follower: TsfFile,
    controller: Controller,
    stats: WelfordStats,
}

/// Run the parallel (barrier-synchronized) sync loop.
pub fn run_parallel(
    master: TsfFile,
    followers: Vec<TsfFile>,
    controllers: Vec<Controller>,
    period_ns: i64,
    stats_interval_cycles: u64,
    rms_warn_us: u64,
) {
    let n = followers.len();
    // Two barriers: one after master read, one after follower writes.
    let barrier1 = Arc::new(Barrier::new(n + 1));
    let barrier2 = Arc::new(Barrier::new(n + 1));
    let master_tsf = Arc::new(AtomicU64::new(0));

    tracing::info!(
        followers = n,
        period_ms = period_ns / 1_000_000,
        "parallel sync loop started ({n} worker threads)"
    );

    // Spawn per-follower worker threads.
    // RT scheduling is inherited from the parent (set before thread::spawn).
    let handles: Vec<_> = followers
        .into_iter()
        .zip(controllers)
        .enumerate()
        .map(|(i, (follower, controller))| {
            let b1 = Arc::clone(&barrier1);
            let b2 = Arc::clone(&barrier2);
            let mt = Arc::clone(&master_tsf);

            std::thread::Builder::new()
                .name(format!("follower-{i}"))
                .spawn(move || {
                    let mut worker = Worker {
                        follower,
                        controller,
                        stats: WelfordStats::new(),
                    };

                    while RUNNING.load(Ordering::SeqCst) {
                        // Wait for master TSF to be published.
                        b1.wait();
                        if !RUNNING.load(Ordering::SeqCst) {
                            break;
                        }

                        let m = mt.load(Ordering::SeqCst);
                        if let Some((step, err)) =
                            correct_follower(&worker.follower, &mut worker.controller, m)
                        {
                            worker.stats.update(err, step);
                        }

                        b2.wait();
                    }

                    worker.stats.print_and_reset(&format!("follower-{i}"));
                })
                .expect("failed to spawn worker thread")
        })
        .collect();

    // Sampler loop: read master, publish, wait for workers.
    let mut deadline = rt::now_monotonic();
    let mut cycle: u64 = 0;
    let mut sampler_stats = WelfordStats::new();

    while RUNNING.load(Ordering::SeqCst) {
        match master.read_tsf() {
            Ok(v) => master_tsf.store(v, Ordering::SeqCst),
            Err(e) => {
                tracing::warn!("master read failed: {e}");
            }
        }

        barrier1.wait();
        barrier2.wait();

        cycle += 1;
        check_stats(
            &mut sampler_stats,
            cycle,
            stats_interval_cycles,
            rms_warn_us,
            "sync",
        );

        rt::advance_deadline(&mut deadline, period_ns);
        rt::sleep_until(&deadline);
    }

    // Unblock workers so they can exit.
    barrier1.wait();

    for h in handles {
        let _ = h.join();
    }

    tracing::info!("parallel sync loop stopped");
}
