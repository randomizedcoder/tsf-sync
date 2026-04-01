//! Inline syscall wrappers for x86_64 Linux.
//!
//! Emit the `syscall` instruction directly, bypassing libc's PLT indirection,
//! errno save/restore, and function-call overhead. Saves ~5-10 instructions
//! per syscall.
//!
//! x86_64 Linux syscall ABI:
//!   rax = syscall number
//!   rdi = arg1, rsi = arg2, rdx = arg3, r10 = arg4, r8 = arg5, r9 = arg6
//!   return value in rax
//!   rcx and r11 are clobbered by the kernel

/// `pread64(2)` via inline `syscall` — reads from fd at offset without lseek.
///
/// Returns bytes read (≥0) or negative errno on failure.
#[cfg(target_arch = "x86_64")]
#[inline(always)]
pub unsafe fn raw_pread64(fd: i32, buf: *mut u8, count: usize, offset: i64) -> isize {
    let ret: isize;
    unsafe {
        core::arch::asm!(
            "syscall",
            inlateout("rax") 17_u64 => ret, // SYS_pread64 = 17
            in("rdi") fd as u64,
            in("rsi") buf as u64,
            in("rdx") count as u64,
            in("r10") offset as u64,
            lateout("rcx") _,
            lateout("r11") _,
            options(nostack, preserves_flags),
        );
    }
    ret
}

/// `pwrite64(2)` via inline `syscall` — writes to fd at offset without lseek.
///
/// Returns bytes written (≥0) or negative errno on failure.
#[cfg(target_arch = "x86_64")]
#[inline(always)]
pub unsafe fn raw_pwrite64(fd: i32, buf: *const u8, count: usize, offset: i64) -> isize {
    let ret: isize;
    unsafe {
        core::arch::asm!(
            "syscall",
            inlateout("rax") 18_u64 => ret, // SYS_pwrite64 = 18
            in("rdi") fd as u64,
            in("rsi") buf as u64,
            in("rdx") count as u64,
            in("r10") offset as u64,
            lateout("rcx") _,
            lateout("r11") _,
            options(nostack, preserves_flags),
        );
    }
    ret
}

/// `clock_nanosleep(2)` via inline `syscall`.
///
/// Returns 0 on success, or a positive errno (e.g., EINTR) on failure.
#[cfg(target_arch = "x86_64")]
#[inline(always)]
pub unsafe fn raw_clock_nanosleep(clockid: i32, flags: i32, rqtp: *const libc::timespec) -> i32 {
    let ret: isize;
    unsafe {
        core::arch::asm!(
            "syscall",
            inlateout("rax") 230_u64 => ret, // SYS_clock_nanosleep = 230
            in("rdi") clockid as u64,
            in("rsi") flags as u64,
            in("rdx") rqtp as u64,
            in("r10") 0_u64,                 // rmtp = NULL (TIMER_ABSTIME ignores it)
            lateout("rcx") _,
            lateout("r11") _,
            options(nostack, preserves_flags),
        );
    }
    ret as i32
}

#[cfg(test)]
#[cfg(target_arch = "x86_64")]
mod tests {
    use super::*;
    use std::io::Write;
    use std::os::unix::io::AsRawFd;

    #[test]
    fn pread64_reads_data() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        tmp.write_all(b"hello world").unwrap();
        tmp.flush().unwrap();

        let fd = tmp.as_file().as_raw_fd();
        let mut buf = [0u8; 5];
        let n = unsafe { raw_pread64(fd, buf.as_mut_ptr(), 5, 0) };
        assert_eq!(n, 5);
        assert_eq!(&buf, b"hello");

        // Read at offset
        let n = unsafe { raw_pread64(fd, buf.as_mut_ptr(), 5, 6) };
        assert_eq!(n, 5);
        assert_eq!(&buf, b"world");
    }

    #[test]
    fn pwrite64_writes_data() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let fd = tmp.as_file().as_raw_fd();

        let data = b"test data";
        let n = unsafe { raw_pwrite64(fd, data.as_ptr(), data.len(), 0) };
        assert_eq!(n, data.len() as isize);

        let mut buf = [0u8; 9];
        let n = unsafe { raw_pread64(fd, buf.as_mut_ptr(), 9, 0) };
        assert_eq!(n, 9);
        assert_eq!(&buf, b"test data");
    }

    #[test]
    fn pread64_bad_fd() {
        let mut buf = [0u8; 1];
        let n = unsafe { raw_pread64(-1, buf.as_mut_ptr(), 1, 0) };
        assert!(n < 0, "expected negative errno, got {n}");
        assert_eq!(n, -(libc::EBADF as isize));
    }

    #[test]
    fn clock_nanosleep_past_deadline() {
        let ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        let ret = unsafe { raw_clock_nanosleep(libc::CLOCK_MONOTONIC, libc::TIMER_ABSTIME, &ts) };
        assert_eq!(ret, 0);
    }
}
