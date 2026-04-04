#!/usr/bin/env bash
# check-asm.sh — Automated assembly verification for tsf-sync-debugfs hot path.
#
# Verifies:
#   1. Inline syscall wrappers emit `syscall` and no `call` (no libc PLT)
#   2. SIMD hex parser uses PMADDUBSW, PMADDWD, PSHUFB (not scalar loop)
#   3. No unexpected function call overhead in the hot path
#
# Usage:
#   ./scripts/check-asm.sh              # build release + check
#   ./scripts/check-asm.sh --dump       # also print the disassembly
#   ./scripts/check-asm.sh --save FILE  # save full disassembly to FILE
set -euo pipefail

DUMP=0
SAVE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dump) DUMP=1; shift ;;
    --save) SAVE="$2"; shift 2 ;;
    *) echo "Usage: $0 [--dump] [--save FILE]"; exit 1 ;;
  esac
done

echo "==> Building release binary..."
cargo build --release --bin tsf-sync-debugfs 2>&1 | tail -3

BIN=$(cargo metadata --format-version 1 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['target_directory'])" 2>/dev/null)/release/tsf-sync-debugfs

if [[ ! -f "$BIN" ]]; then
  # Fallback: check common locations
  for candidate in target/release/tsf-sync-debugfs /tmp/tsf-sync-target/release/tsf-sync-debugfs; do
    if [[ -f "$candidate" ]]; then
      BIN="$candidate"
      break
    fi
  done
fi

if [[ ! -f "$BIN" ]]; then
  echo "ERROR: Cannot find release binary" >&2
  exit 1
fi

echo "==> Binary: $BIN"
echo "==> Disassembling..."

FULL_ASM=$(objdump -d -M intel --demangle "$BIN")

if [[ -n "$SAVE" ]]; then
  echo "$FULL_ASM" > "$SAVE"
  echo "==> Full disassembly saved to $SAVE"
fi

PASS=0
FAIL=0

check() {
  local name="$1"
  local pattern="$2"
  local mode="$3"  # "present" or "absent"
  local context="$4"

  if [[ "$mode" == "present" ]]; then
    if echo "$context" | grep -qi "$pattern"; then
      echo "  PASS: $name — found '$pattern'"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $name — expected '$pattern' not found"
      FAIL=$((FAIL + 1))
    fi
  else
    if echo "$context" | grep -qi "$pattern"; then
      echo "  FAIL: $name — unexpected '$pattern' found"
      FAIL=$((FAIL + 1))
    else
      echo "  PASS: $name — no '$pattern' (correct)"
      PASS=$((PASS + 1))
    fi
  fi
}

# ─── Extract function bodies ──────────────────────────────────────────────────
# objdump labels: <module::function>

extract_fn() {
  local pattern="$1"
  # Demangled Rust symbols look like: <tsf_sync_debugfs::debugfs::TsfFile::read_tsf>:
  # Use grep to find the label line, then awk from there to next blank line.
  echo "$FULL_ASM" | awk "/${pattern}.*>:/,/^$/" 2>/dev/null || true
}

# Find the SIMD parser and syscall functions.
# With inlining, they may be embedded in read_tsf/write_tsf/sleep_until.
# We check the surrounding functions too.

PARSE_FN=$(extract_fn "parse_hex_auto")
READ_FN=$(extract_fn "TsfFile::read_tsf")
WRITE_FN=$(extract_fn "TsfFile::write_tsf")
SLEEP_FN=$(extract_fn "rt::sleep_until")

# Also check for the functions being inlined into the sync loop.
SINGLE_FN=$(extract_fn "threading::run_single")

echo ""
echo "==> Checking inline syscalls..."

# The raw syscall wrappers are #[inline(always)], so they'll be inlined
# into read_tsf, write_tsf, sleep_until, or run_single.
# We check that these callers contain `syscall` and ideally no `call.*pread`.

HOTPATH="$READ_FN$WRITE_FN$SLEEP_FN$SINGLE_FN"

check "syscall instruction in hot path" "syscall" "present" "$HOTPATH"
check "no libc pread PLT call" "call.*pread" "absent" "$HOTPATH"
check "no libc pwrite PLT call" "call.*pwrite" "absent" "$HOTPATH"
check "no libc clock_nanosleep PLT call" "call.*clock_nanosleep" "absent" "$HOTPATH"

echo ""
echo "==> Checking SIMD hex parser..."

SSSE3_FN=$(extract_fn "parse_hex_16_ssse3")
SIMD_CONTEXT="$PARSE_FN$SSSE3_FN$READ_FN$SINGLE_FN"

check "PMADDUBSW present" "pmaddubsw" "present" "$SIMD_CONTEXT"
check "PMADDWD present" "pmaddwd" "present" "$SIMD_CONTEXT"
check "PSHUFB present" "pshufb" "present" "$SIMD_CONTEXT"

echo ""
echo "==> Checking binary size..."
SIZE=$(wc -c < "$BIN")
SIZE_KB=$((SIZE / 1024))
echo "  Binary size: ${SIZE_KB} KB"

if [[ $DUMP -eq 1 ]]; then
  echo ""
  echo "==> Hot path disassembly:"
  echo ""
  if [[ -n "$PARSE_FN" ]]; then
    echo "--- parse_hex_16_ssse3 ---"
    echo "$PARSE_FN"
    echo ""
  fi
  if [[ -n "$READ_FN" ]]; then
    echo "--- read_tsf ---"
    echo "$READ_FN"
    echo ""
  fi
  if [[ -n "$WRITE_FN" ]]; then
    echo "--- write_tsf ---"
    echo "$WRITE_FN"
    echo ""
  fi
fi

echo ""
echo "========================================"
if [[ $FAIL -eq 0 ]]; then
  echo "  ALL $PASS CHECKS PASSED"
else
  echo "  $FAIL FAILED, $PASS passed"
fi
echo "========================================"

exit $FAIL
