//! Criterion benchmarks for the tsf-sync-debugfs hot path.
//!
//! Measures:
//! - Hex parsing: SIMD (SSSE3) vs scalar, on the exact debugfs format
//! - Decimal formatting: u64 → ASCII
//! - Inline syscall vs libc syscall overhead (pread on /dev/null)
//!
//! Run: cargo bench --bench hot_path
//! Or via Nix: nix run .#bench-hot-path

use criterion::{black_box, criterion_group, criterion_main, Criterion};

// ─── Hex parsing: we inline the relevant functions from the binary ────────────
// (The binary's modules aren't a library, so we reimplement the core logic here
// to benchmark it in isolation.)

/// Scalar hex parser (same as debugfs.rs / asm.rs scalar path).
fn parse_hex_scalar(buf: &[u8]) -> u64 {
    let mut i = 0;
    while i < buf.len() && buf[i].is_ascii_whitespace() {
        i += 1;
    }
    if i + 1 < buf.len() && buf[i] == b'0' && (buf[i + 1] == b'x' || buf[i + 1] == b'X') {
        i += 2;
    }
    let mut val: u64 = 0;
    while i < buf.len() {
        let nibble = match buf[i] {
            b'0'..=b'9' => buf[i] - b'0',
            b'a'..=b'f' => buf[i] - b'a' + 10,
            b'A'..=b'F' => buf[i] - b'A' + 10,
            _ => break,
        };
        val = (val << 4) | nibble as u64;
        i += 1;
    }
    val
}

/// SSSE3 SIMD hex parser (same as asm.rs).
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "ssse3")]
unsafe fn parse_hex_16_ssse3(hex: *const u8) -> u64 {
    use core::arch::x86_64::*;

    unsafe {
        let input = _mm_loadu_si128(hex as *const __m128i);
        let low_nibble = _mm_and_si128(input, _mm_set1_epi8(0x0F));
        let is_letter = _mm_cmpgt_epi8(input, _mm_set1_epi8(0x39));
        let letter_adj = _mm_and_si128(is_letter, _mm_set1_epi8(9));
        let nibbles = _mm_add_epi8(low_nibble, letter_adj);

        let mul_16_1 = _mm_set_epi8(1, 16, 1, 16, 1, 16, 1, 16, 1, 16, 1, 16, 1, 16, 1, 16);
        let bytes = _mm_maddubs_epi16(nibbles, mul_16_1);

        let mul_256_1 = _mm_set_epi16(1, 256, 1, 256, 1, 256, 1, 256);
        let words = _mm_madd_epi16(bytes, mul_256_1);

        let shuffle = _mm_set_epi8(-1, -1, -1, -1, -1, -1, -1, -1, 1, 0, 5, 4, 9, 8, 13, 12);
        let packed = _mm_shuffle_epi8(words, shuffle);
        _mm_cvtsi128_si64(packed) as u64
    }
}

/// Decimal formatter (same as debugfs.rs).
fn format_u64_decimal(mut val: u64, buf: &mut [u8; 21]) -> usize {
    if val == 0 {
        buf[0] = b'0';
        buf[1] = b'\n';
        return 2;
    }
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

// ─── Inline syscall wrappers ──────────────────────────────────────────────────

#[cfg(target_arch = "x86_64")]
#[inline(always)]
unsafe fn raw_pread64(fd: i32, buf: *mut u8, count: usize, offset: i64) -> isize {
    let ret: isize;
    unsafe {
        core::arch::asm!(
            "syscall",
            inlateout("rax") 17_u64 => ret,
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

// ─── Benchmarks ───────────────────────────────────────────────────────────────

fn bench_hex_parse(c: &mut Criterion) {
    // Typical debugfs output: "0x%016llx\n"
    let input = b"0x000000e8d4a51000\n";
    let hex16 = b"000000e8d4a51000";
    let expected = 0x000000e8d4a51000u64;

    let mut group = c.benchmark_group("hex_parse");

    group.bench_function("scalar", |b| {
        b.iter(|| {
            let v = parse_hex_scalar(black_box(input));
            debug_assert_eq!(v, expected);
            v
        })
    });

    #[cfg(target_arch = "x86_64")]
    {
        if std::is_x86_feature_detected!("ssse3") {
            group.bench_function("ssse3_simd", |b| {
                b.iter(|| {
                    let v = unsafe { parse_hex_16_ssse3(black_box(hex16).as_ptr()) };
                    debug_assert_eq!(v, expected);
                    v
                })
            });
        }
    }

    group.finish();
}

fn bench_decimal_format(c: &mut Criterion) {
    let mut group = c.benchmark_group("decimal_format");

    group.bench_function("typical_tsf", |b| {
        b.iter(|| {
            let mut buf = [0u8; 21];
            format_u64_decimal(black_box(1_000_000_000_000u64), &mut buf)
        })
    });

    group.bench_function("max_u64", |b| {
        b.iter(|| {
            let mut buf = [0u8; 21];
            format_u64_decimal(black_box(u64::MAX), &mut buf)
        })
    });

    group.finish();
}

fn bench_syscall(c: &mut Criterion) {
    use std::fs::OpenOptions;
    use std::os::unix::io::AsRawFd;

    // Open /dev/null for benchmarking syscall overhead (not the I/O itself).
    let file = OpenOptions::new()
        .read(true)
        .open("/dev/null")
        .expect("/dev/null");
    let fd = file.as_raw_fd();

    let mut group = c.benchmark_group("syscall_overhead");

    group.bench_function("libc_pread", |b| {
        b.iter(|| {
            let mut buf = [0u8; 64];
            unsafe { libc::pread(black_box(fd), buf.as_mut_ptr().cast(), 64, 0) }
        })
    });

    #[cfg(target_arch = "x86_64")]
    {
        group.bench_function("inline_syscall_pread", |b| {
            b.iter(|| {
                let mut buf = [0u8; 64];
                unsafe { raw_pread64(black_box(fd), buf.as_mut_ptr(), 64, 0) }
            })
        });
    }

    group.finish();
}

criterion_group!(
    benches,
    bench_hex_parse,
    bench_decimal_format,
    bench_syscall
);
criterion_main!(benches);
