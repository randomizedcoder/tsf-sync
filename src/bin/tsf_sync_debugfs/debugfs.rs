use std::fs::OpenOptions;
use std::io;
use std::os::unix::io::{AsRawFd, OwnedFd};
use std::path::Path;

use crate::asm;

/// Cached file descriptor for a debugfs TSF file.
///
/// FiWiTSF does open/read/close (3 syscalls) per access.
/// We open once and use inline-syscall pread/pwrite (1 `syscall` instruction each),
/// bypassing both the 3-syscall overhead *and* libc's PLT/errno wrapper.
pub struct TsfFile {
    fd: OwnedFd,
    /// True if pread works on this filesystem (detected once at open).
    pread_ok: bool,
}

impl TsfFile {
    /// Open a debugfs TSF file, caching the fd for the lifetime of this struct.
    /// Tests whether pread works (debugfs sometimes requires lseek+read).
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = OpenOptions::new().read(true).write(true).open(path)?;
        let fd: OwnedFd = file.into();

        // Probe pread support: try a 1-byte pread at offset 0.
        let mut probe = [0u8; 1];
        let pread_ok = do_pread(fd.as_raw_fd(), &mut probe, 0) >= 0;

        Ok(Self { fd, pread_ok })
    }

    /// Read the current TSF value (hex string like "0x00001234abcd\n").
    ///
    /// Hot path: one inline `syscall` instruction (pread64) + SSSE3 SIMD hex
    /// parse when the kernel returns the standard 16-digit format.
    pub fn read_tsf(&self) -> io::Result<u64> {
        let mut buf = [0u8; 64];
        let n = self.read_raw(&mut buf)?;
        asm::parse_hex_auto(&buf[..n])
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "no hex digits in TSF value"))
    }

    /// Write a TSF value (decimal string) to the debugfs file.
    ///
    /// Hot path: one inline `syscall` instruction (pwrite64).
    pub fn write_tsf(&self, val: u64) -> io::Result<()> {
        let mut buf = [0u8; 21]; // max u64 decimal = 20 digits + newline
        let len = format_u64_decimal(val, &mut buf);
        self.write_raw(&buf[..len])
    }

    /// Read raw bytes from the file at offset 0.
    ///
    /// Uses pread when supported, falls back to lseek+read.
    #[inline(always)]
    fn read_raw(&self, buf: &mut [u8]) -> io::Result<usize> {
        if self.pread_ok {
            let r = do_pread(self.fd.as_raw_fd(), buf, 0);
            if r < 0 {
                return Err(io::Error::from_raw_os_error(-r as i32));
            }
            Ok(r as usize)
        } else {
            unsafe {
                libc::lseek(self.fd.as_raw_fd(), 0, libc::SEEK_SET);
            }
            let r = unsafe { libc::read(self.fd.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
            if r < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(r as usize)
        }
    }

    /// Write raw bytes to the file at offset 0.
    ///
    /// Uses pwrite when supported, falls back to lseek+write.
    #[inline(always)]
    fn write_raw(&self, buf: &[u8]) -> io::Result<()> {
        let written = if self.pread_ok {
            do_pwrite(self.fd.as_raw_fd(), buf, 0)
        } else {
            unsafe {
                libc::lseek(self.fd.as_raw_fd(), 0, libc::SEEK_SET);
            }
            unsafe { libc::write(self.fd.as_raw_fd(), buf.as_ptr().cast(), buf.len()) as isize }
        };

        if written < 0 {
            return Err(io::Error::from_raw_os_error(-written as i32));
        }
        Ok(())
    }
}

// ─── Syscall dispatch ─────────────────────────────────────────────────────────

/// pread wrapper: inline `syscall` on x86_64, libc fallback otherwise.
/// Returns bytes read or negative errno.
#[inline(always)]
fn do_pread(fd: i32, buf: &mut [u8], offset: i64) -> isize {
    #[cfg(target_arch = "x86_64")]
    {
        unsafe { asm::raw_pread64(fd, buf.as_mut_ptr(), buf.len(), offset) }
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        let r = unsafe { libc::pread(fd, buf.as_mut_ptr().cast(), buf.len(), offset) };
        if r < 0 {
            -(unsafe { *libc::__errno_location() } as isize)
        } else {
            r as isize
        }
    }
}

/// pwrite wrapper: inline `syscall` on x86_64, libc fallback otherwise.
/// Returns bytes written or negative errno.
#[inline(always)]
fn do_pwrite(fd: i32, buf: &[u8], offset: i64) -> isize {
    #[cfg(target_arch = "x86_64")]
    {
        unsafe { asm::raw_pwrite64(fd, buf.as_ptr(), buf.len(), offset) }
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        let r = unsafe { libc::pwrite(fd, buf.as_ptr().cast(), buf.len(), offset) };
        if r < 0 {
            -(unsafe { *libc::__errno_location() } as isize)
        } else {
            r as isize
        }
    }
}

// ─── Formatting ───────────────────────────────────────────────────────────────

/// Format a u64 as decimal into a stack buffer. Returns the number of bytes written.
fn format_u64_decimal(mut val: u64, buf: &mut [u8; 21]) -> usize {
    if val == 0 {
        buf[0] = b'0';
        buf[1] = b'\n';
        return 2;
    }

    // Write digits in reverse, then reverse them.
    let mut pos = 0;
    while val > 0 {
        buf[pos] = b'0' + (val % 10) as u8;
        val /= 10;
        pos += 1;
    }
    buf[..pos].reverse();
    buf[pos] = b'\n';
    pos + 1
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    // ── Decimal formatting ──

    #[test]
    fn format_decimal_zero() {
        let mut buf = [0u8; 21];
        let n = format_u64_decimal(0, &mut buf);
        assert_eq!(&buf[..n], b"0\n");
    }

    #[test]
    fn format_decimal_max() {
        let mut buf = [0u8; 21];
        let n = format_u64_decimal(u64::MAX, &mut buf);
        assert_eq!(&buf[..n], b"18446744073709551615\n");
    }

    #[test]
    fn format_decimal_typical() {
        let mut buf = [0u8; 21];
        let n = format_u64_decimal(123456789, &mut buf);
        assert_eq!(&buf[..n], b"123456789\n");
    }

    // ── TsfFile I/O via tempfile ──

    #[test]
    fn read_tsf_parses_hex() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        tmp.write_all(b"0x000000e8d4a51000\n").unwrap();
        tmp.flush().unwrap();
        let tsf = TsfFile::open(tmp.path()).unwrap();
        assert_eq!(tsf.read_tsf().unwrap(), 0x000000e8d4a51000);
    }

    #[test]
    fn write_tsf_writes_decimal() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().to_owned();
        let tsf = TsfFile::open(tmp.path()).unwrap();
        tsf.write_tsf(12345).unwrap();
        let content = std::fs::read(&path).unwrap();
        assert_eq!(&content, b"12345\n");
    }

    #[test]
    fn read_tsf_zero_value() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        tmp.write_all(b"0x0000000000000000\n").unwrap();
        tmp.flush().unwrap();
        let tsf = TsfFile::open(tmp.path()).unwrap();
        assert_eq!(tsf.read_tsf().unwrap(), 0);
    }

    #[test]
    fn read_tsf_max_value() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        tmp.write_all(b"0xffffffffffffffff\n").unwrap();
        tmp.flush().unwrap();
        let tsf = TsfFile::open(tmp.path()).unwrap();
        assert_eq!(tsf.read_tsf().unwrap(), u64::MAX);
    }

    #[test]
    fn read_tsf_invalid_returns_error() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        tmp.write_all(b"\n").unwrap();
        tmp.flush().unwrap();
        let tsf = TsfFile::open(tmp.path()).unwrap();
        assert!(tsf.read_tsf().is_err());
    }
}
