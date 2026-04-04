//! Hex string parsing: SSSE3 SIMD fast path with scalar fallback.
//!
//! The debugfs TSF file outputs `0x%016llx\n` (exactly 16 hex digits).
//! A SSSE3 pipeline converts all 16 digits in ~8 instructions vs the
//! scalar loop's ~48.
//!
//! Pipeline (operates on all 16 digits simultaneously):
//!
//!   Step 1: Load 16 ASCII hex bytes into XMM register
//!   Step 2: Convert ASCII → 4-bit nibble values (0–15)
//!            - (byte & 0x0F) gives correct value for '0'–'9'
//!            - For 'a'–'f'/'A'–'F', add 9 (detected via byte > '9')
//!   Step 3: PMADDUBSW with [16,1,16,1,...] — pack pairs of nibbles into bytes
//!   Step 4: PMADDWD with [256,1,256,1,...] — pack pairs of bytes into u16
//!   Step 5: PSHUFB to gather the 4 u16 values into a single u64 (big→little endian)

/// Parse exactly 16 hex ASCII digits into a u64 using SSSE3 SIMD.
///
/// # Safety
/// - `hex` must point to at least 16 readable bytes of valid hex ASCII.
/// - Caller must verify SSSE3 is available (or use `#[target_feature]` dispatch).
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "ssse3")]
pub unsafe fn parse_hex_16_ssse3(hex: *const u8) -> u64 {
    use core::arch::x86_64::*;

    unsafe {
        let input = _mm_loadu_si128(hex as *const __m128i);

        // ASCII → nibble
        let low_nibble = _mm_and_si128(input, _mm_set1_epi8(0x0F));
        let is_letter = _mm_cmpgt_epi8(input, _mm_set1_epi8(0x39));
        let letter_adj = _mm_and_si128(is_letter, _mm_set1_epi8(9));
        let nibbles = _mm_add_epi8(low_nibble, letter_adj);

        // PMADDUBSW — pack nibble pairs into bytes
        let mul_16_1 = _mm_set_epi8(1, 16, 1, 16, 1, 16, 1, 16, 1, 16, 1, 16, 1, 16, 1, 16);
        let bytes = _mm_maddubs_epi16(nibbles, mul_16_1);

        // PMADDWD — pack byte pairs into u16 values
        let mul_256_1 = _mm_set_epi16(1, 256, 1, 256, 1, 256, 1, 256);
        let words = _mm_madd_epi16(bytes, mul_256_1);

        // PSHUFB — gather 4×u16 into little-endian u64
        let shuffle = _mm_set_epi8(
            -1, -1, -1, -1, -1, -1, -1, -1, // high 64 bits: zeroed
            1, 0, 5, 4, 9, 8, 13, 12, // low 64 bits: gather u16s, reverse group order
        );
        let packed = _mm_shuffle_epi8(words, shuffle);

        _mm_cvtsi128_si64(packed) as u64
    }
}

/// Returns true if the CPU supports SSSE3 (checked once, cached).
#[cfg(target_arch = "x86_64")]
pub fn has_ssse3() -> bool {
    std::is_x86_feature_detected!("ssse3")
}

/// Scalar fallback: parse variable-length hex digits into u64.
/// Used when input isn't exactly 16 digits or SSSE3 is unavailable.
pub fn parse_hex_scalar(buf: &[u8]) -> Option<u64> {
    let mut i = 0;
    while i < buf.len() && buf[i].is_ascii_whitespace() {
        i += 1;
    }
    if i + 1 < buf.len() && buf[i] == b'0' && (buf[i + 1] == b'x' || buf[i + 1] == b'X') {
        i += 2;
    }

    let mut val: u64 = 0;
    let mut digits: u32 = 0;
    while i < buf.len() {
        let nibble = match buf[i] {
            b'0'..=b'9' => buf[i] - b'0',
            b'a'..=b'f' => buf[i] - b'a' + 10,
            b'A'..=b'F' => buf[i] - b'A' + 10,
            _ => break,
        };
        val = val.checked_shl(4)? | nibble as u64;
        digits += 1;
        i += 1;
    }
    if digits == 0 {
        None
    } else {
        Some(val)
    }
}

/// Parse a TSF hex string using the fastest available method.
///
/// Tries SSSE3 fast path for exactly 16-digit values (the common case),
/// falls back to scalar for anything else.
#[cfg(target_arch = "x86_64")]
pub fn parse_hex_auto(buf: &[u8]) -> Option<u64> {
    // Fast path: "0x" + exactly 16 hex digits + "\n" = 19 bytes
    // (this is what debugfs always produces via `0x%016llx\n`)
    if buf.len() >= 19 && buf[0] == b'0' && (buf[1] == b'x' || buf[1] == b'X') && has_ssse3() {
        let hex_slice = &buf[2..18];
        if hex_slice.iter().all(|b| b.is_ascii_hexdigit()) {
            return Some(unsafe { parse_hex_16_ssse3(hex_slice.as_ptr()) });
        }
    }
    parse_hex_scalar(buf)
}

#[cfg(not(target_arch = "x86_64"))]
pub fn parse_hex_auto(buf: &[u8]) -> Option<u64> {
    parse_hex_scalar(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Scalar parser tests ──

    #[test]
    fn scalar_basic() {
        assert_eq!(parse_hex_scalar(b"0x1234abcd\n"), Some(0x1234abcd));
    }

    #[test]
    fn scalar_no_prefix() {
        assert_eq!(parse_hex_scalar(b"ff\n"), Some(0xff));
    }

    #[test]
    fn scalar_max_u64() {
        assert_eq!(parse_hex_scalar(b"0xffffffffffffffff\n"), Some(u64::MAX));
    }

    #[test]
    fn scalar_zero() {
        assert_eq!(parse_hex_scalar(b"0x0\n"), Some(0));
    }

    #[test]
    fn scalar_empty() {
        assert_eq!(parse_hex_scalar(b"\n"), None);
    }

    // ── SIMD parser tests (x86_64 only) ──

    #[cfg(target_arch = "x86_64")]
    mod simd {
        use super::*;

        fn ssse3_parse(hex16: &[u8; 16]) -> u64 {
            assert!(has_ssse3(), "SSSE3 required for this test");
            unsafe { parse_hex_16_ssse3(hex16.as_ptr()) }
        }

        #[test]
        fn all_zeros() {
            assert_eq!(ssse3_parse(b"0000000000000000"), 0);
        }

        #[test]
        fn all_ones() {
            assert_eq!(ssse3_parse(b"ffffffffffffffff"), u64::MAX);
        }

        #[test]
        fn sequential() {
            assert_eq!(ssse3_parse(b"0123456789abcdef"), 0x0123456789abcdef);
        }

        #[test]
        fn uppercase() {
            assert_eq!(ssse3_parse(b"0123456789ABCDEF"), 0x0123456789ABCDEF);
        }

        #[test]
        fn mixed_case() {
            assert_eq!(ssse3_parse(b"aAbBcCdDeEfF0123"), 0xAABBCCDDEEFF0123);
        }

        #[test]
        fn one() {
            assert_eq!(ssse3_parse(b"0000000000000001"), 1);
        }

        #[test]
        fn high_bit() {
            assert_eq!(ssse3_parse(b"8000000000000000"), 0x8000000000000000);
        }

        #[test]
        fn typical_tsf() {
            assert_eq!(ssse3_parse(b"000000e8d4a51000"), 0x000000e8d4a51000);
        }

        /// Verify SIMD matches scalar for every single-digit value in every position.
        #[test]
        fn vs_scalar_exhaustive_digits() {
            let digits = b"0123456789abcdef";
            for &d in digits {
                let mut buf = [b'0'; 16];
                for pos in 0..16 {
                    buf[pos] = d;
                    let simd_val = ssse3_parse(&buf);
                    let hex_str = format!("0x{}\n", std::str::from_utf8(&buf).unwrap());
                    let scalar_val = parse_hex_scalar(hex_str.as_bytes()).unwrap();
                    assert_eq!(
                        simd_val, scalar_val,
                        "mismatch at pos={pos} digit=0x{d:02x}: simd=0x{simd_val:016x} scalar=0x{scalar_val:016x}"
                    );
                    buf[pos] = b'0';
                }
            }
        }

        /// Round-trip: format u64 as hex, parse back with SIMD, verify match.
        #[test]
        fn round_trip() {
            let values: &[u64] = &[
                0,
                1,
                0xFF,
                0xDEAD_BEEF,
                0x0123_4567_89AB_CDEF,
                u64::MAX,
                u64::MAX / 2,
                0x8000_0000_0000_0000,
            ];
            for &v in values {
                let hex = format!("{v:016x}");
                let result = ssse3_parse(hex.as_bytes().try_into().unwrap());
                assert_eq!(result, v, "round-trip failed for 0x{v:016x}");
            }
        }
    }

    // ── Auto-dispatch tests ──

    #[test]
    fn auto_standard_debugfs_format() {
        assert_eq!(parse_hex_auto(b"0x0000000012345678\n"), Some(0x12345678));
    }

    #[test]
    fn auto_max_value() {
        assert_eq!(parse_hex_auto(b"0xffffffffffffffff\n"), Some(u64::MAX));
    }

    #[test]
    fn auto_short_value_falls_back_to_scalar() {
        assert_eq!(parse_hex_auto(b"0xff\n"), Some(0xff));
    }
}
