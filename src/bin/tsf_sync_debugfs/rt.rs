use std::io;

/// Lock all current and future memory pages (prevents paging jitter).
pub fn lock_memory() -> io::Result<()> {
    let ret = unsafe { libc::mlockall(libc::MCL_CURRENT | libc::MCL_FUTURE) };
    if ret != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Set SCHED_FIFO real-time scheduling with the given priority.
pub fn set_rt_priority(priority: u32) -> io::Result<()> {
    let param = libc::sched_param {
        sched_priority: priority as i32,
    };
    let ret = unsafe { libc::sched_setscheduler(0, libc::SCHED_FIFO, &param) };
    if ret != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Pin the current process to a specific CPU core.
pub fn set_cpu_affinity(cpu_id: usize) -> io::Result<()> {
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_ZERO(&mut set);
        libc::CPU_SET(cpu_id, &mut set);
        let ret = libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set);
        if ret != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Lock memory, set SCHED_FIFO, and optionally pin to a CPU.
pub fn setup_rt(priority: u32, cpu: Option<usize>) -> io::Result<()> {
    lock_memory()?;
    set_rt_priority(priority)?;
    if let Some(cpu_id) = cpu {
        set_cpu_affinity(cpu_id)?;
    }
    Ok(())
}

/// Get the current CLOCK_MONOTONIC time.
pub fn now_monotonic() -> libc::timespec {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe {
        libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts);
    }
    ts
}

/// Advance a deadline by `period_ns` nanoseconds.
pub fn advance_deadline(ts: &mut libc::timespec, period_ns: i64) {
    ts.tv_nsec += period_ns;
    while ts.tv_nsec >= 1_000_000_000 {
        ts.tv_sec += 1;
        ts.tv_nsec -= 1_000_000_000;
    }
}

/// Sleep until an absolute CLOCK_MONOTONIC deadline, retrying on EINTR.
///
/// On x86_64: uses inline `syscall` instruction, bypassing libc entirely.
pub fn sleep_until(deadline: &libc::timespec) {
    loop {
        let ret = do_clock_nanosleep(deadline);
        if ret == 0 || ret != libc::EINTR {
            break;
        }
    }
}

#[inline(always)]
fn do_clock_nanosleep(rqtp: &libc::timespec) -> i32 {
    #[cfg(target_arch = "x86_64")]
    {
        unsafe { crate::asm::raw_clock_nanosleep(libc::CLOCK_MONOTONIC, libc::TIMER_ABSTIME, rqtp) }
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        unsafe {
            libc::clock_nanosleep(
                libc::CLOCK_MONOTONIC,
                libc::TIMER_ABSTIME,
                rqtp,
                std::ptr::null_mut(),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn advance_simple() {
        let mut ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        advance_deadline(&mut ts, 10_000_000); // 10ms
        assert_eq!(ts.tv_sec, 0);
        assert_eq!(ts.tv_nsec, 10_000_000);
    }

    #[test]
    fn advance_wraps_second() {
        let mut ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 999_000_000,
        };
        advance_deadline(&mut ts, 10_000_000); // pushes past 1s
        assert_eq!(ts.tv_sec, 1);
        assert_eq!(ts.tv_nsec, 9_000_000);
    }

    #[test]
    fn advance_multiple_seconds() {
        let mut ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        advance_deadline(&mut ts, 2_500_000_000); // 2.5s
        assert_eq!(ts.tv_sec, 2);
        assert_eq!(ts.tv_nsec, 500_000_000);
    }

    #[test]
    fn advance_accumulates() {
        let mut ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        for _ in 0..100 {
            advance_deadline(&mut ts, 10_000_000); // 100 × 10ms = 1s
        }
        assert_eq!(ts.tv_sec, 1);
        assert_eq!(ts.tv_nsec, 0);
    }

    #[test]
    fn now_monotonic_returns_positive() {
        let ts = now_monotonic();
        assert!(ts.tv_sec > 0 || ts.tv_nsec > 0);
    }

    #[test]
    fn now_monotonic_increases() {
        let t1 = now_monotonic();
        let t2 = now_monotonic();
        let ns1 = t1.tv_sec as i128 * 1_000_000_000 + t1.tv_nsec as i128;
        let ns2 = t2.tv_sec as i128 * 1_000_000_000 + t2.tv_nsec as i128;
        assert!(ns2 >= ns1, "monotonic clock should not go backwards");
    }
}
