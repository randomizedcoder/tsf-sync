//! Architecture-specific hot-path optimizations.
//!
//! Two classes of optimization over the libc-based path:
//!
//! 1. **Inline syscalls** — emit the `syscall` instruction directly, bypassing
//!    libc's PLT indirection, errno save/restore, and function-call overhead.
//!    Saves ~5-10 instructions per syscall.
//!
//! 2. **SIMD hex parser** — the debugfs TSF file outputs `0x%016llx\n` (exactly
//!    16 hex digits). A SSSE3 pipeline converts all 16 digits in ~8 instructions
//!    vs the scalar loop's ~48.
//!
//! Everything is `#[cfg(target_arch = "x86_64")]` gated with scalar fallbacks.

mod hex;
mod syscall;

pub use hex::*;
pub use syscall::*;
