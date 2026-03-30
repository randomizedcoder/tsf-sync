#!/usr/bin/env bash
# Validate that mac80211_hwsim TSF access works on this system.
# This is a quick smoke test that doesn't require tsf-ptp — just hwsim.
#
# What it proves:
#   - mac80211_hwsim loads and creates radios with get_tsf/set_tsf
#   - debugfs TSF read/write works (the same ops our kernel module will call)
#   - TSF values are sane (ktime-based, advancing in real time)
#   - Multiple radios have independent TSF offsets
#   - The driver is identifiable via sysfs
#
# Usage: sudo ./validate_hwsim_tsf.sh [radios=4]

set -euo pipefail

RADIOS="${1:-4}"
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; ((PASS++)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; ((FAIL++)); }

cleanup() {
    rmmod mac80211_hwsim 2>/dev/null || true
}
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root"
    exit 1
fi

echo "=== mac80211_hwsim TSF validation ==="
echo ""

# Clean state
rmmod mac80211_hwsim 2>/dev/null || true

# --- Load hwsim ---

echo "--- Loading mac80211_hwsim radios=$RADIOS ---"
modprobe mac80211_hwsim radios="$RADIOS"

# Verify phys
PHY_COUNT=0
for phy in /sys/class/ieee80211/phy*; do
    [ -d "$phy" ] || continue
    PHY_NAME=$(basename "$phy")
    DRIVER=$(basename "$(readlink "$phy/device/driver" 2>/dev/null)" 2>/dev/null || echo "?")
    if [ "$DRIVER" = "mac80211_hwsim" ]; then
        ((PHY_COUNT++))
        echo "  Found: $PHY_NAME (driver=$DRIVER)"
    fi
done

if [ "$PHY_COUNT" -ge "$RADIOS" ]; then
    pass "loaded $PHY_COUNT hwsim radios"
else
    fail "expected $RADIOS radios, found $PHY_COUNT"
fi

# --- TSF debugfs reads ---

echo ""
echo "--- Reading TSF via debugfs ---"

# Find all wlan interfaces and their TSF files
declare -a TSF_VALUES=()
for wlan in /sys/class/net/wlan*; do
    [ -d "$wlan" ] || continue
    WLAN_NAME=$(basename "$wlan")
    PHY_LINK=$(readlink "$wlan/phy80211" 2>/dev/null || continue)
    PHY_NAME=$(basename "$PHY_LINK")
    TSF_FILE="/sys/kernel/debug/ieee80211/$PHY_NAME/netdev:$WLAN_NAME/tsf"

    if [ -f "$TSF_FILE" ]; then
        TSF=$(cat "$TSF_FILE")
        TSF_VALUES+=("$TSF")
        echo "  $WLAN_NAME ($PHY_NAME): TSF = $TSF µs"

        if [ "$TSF" -gt 0 ] 2>/dev/null; then
            pass "$WLAN_NAME TSF read is positive"
        else
            fail "$WLAN_NAME TSF read: '$TSF'"
        fi
    else
        echo "  $WLAN_NAME ($PHY_NAME): no debugfs TSF file"
    fi
done

# --- TSF write + readback ---

echo ""
echo "--- TSF write + readback ---"

# Find the first wlan with a TSF file
for wlan in /sys/class/net/wlan*; do
    [ -d "$wlan" ] || continue
    WLAN_NAME=$(basename "$wlan")
    PHY_LINK=$(readlink "$wlan/phy80211" 2>/dev/null || continue)
    PHY_NAME=$(basename "$PHY_LINK")
    TSF_FILE="/sys/kernel/debug/ieee80211/$PHY_NAME/netdev:$WLAN_NAME/tsf"
    [ -f "$TSF_FILE" ] || continue

    # Write a distinctive value
    WRITE_VAL=5000000000  # 5000 seconds
    echo "$WRITE_VAL" > "$TSF_FILE"
    sleep 0.01  # 10ms
    READBACK=$(cat "$TSF_FILE")

    DELTA=$((READBACK - WRITE_VAL))
    if [ "$DELTA" -ge 0 ] && [ "$DELTA" -lt 100000 ]; then
        pass "$WLAN_NAME TSF write→read: wrote $WRITE_VAL, read $READBACK (delta ${DELTA}µs)"
    else
        fail "$WLAN_NAME TSF write→read: wrote $WRITE_VAL, read $READBACK (delta ${DELTA}µs)"
    fi

    # Verify TSF advances in real time
    TSF1=$(cat "$TSF_FILE")
    sleep 0.1  # 100ms
    TSF2=$(cat "$TSF_FILE")
    ADVANCE=$((TSF2 - TSF1))

    # Should have advanced ~100,000 µs (100ms), allow 50-200ms range
    if [ "$ADVANCE" -gt 50000 ] && [ "$ADVANCE" -lt 200000 ]; then
        pass "$WLAN_NAME TSF advancing in real time: +${ADVANCE}µs in ~100ms"
    else
        fail "$WLAN_NAME TSF advance: +${ADVANCE}µs in ~100ms (expected ~100000)"
    fi

    break  # Only test one
done

# --- Independent TSF offsets ---

echo ""
echo "--- Independent TSF offsets between radios ---"

# Set radio 0 to 1,000,000 and radio 1 to 9,000,000
# Then verify they read differently
WLANS=()
TSF_FILES=()
for wlan in /sys/class/net/wlan*; do
    [ -d "$wlan" ] || continue
    WLAN_NAME=$(basename "$wlan")
    PHY_LINK=$(readlink "$wlan/phy80211" 2>/dev/null || continue)
    PHY_NAME=$(basename "$PHY_LINK")
    TSF_FILE="/sys/kernel/debug/ieee80211/$PHY_NAME/netdev:$WLAN_NAME/tsf"
    [ -f "$TSF_FILE" ] || continue
    WLANS+=("$WLAN_NAME")
    TSF_FILES+=("$TSF_FILE")
done

if [ "${#TSF_FILES[@]}" -ge 2 ]; then
    echo "1000000" > "${TSF_FILES[0]}"
    echo "9000000" > "${TSF_FILES[1]}"
    sleep 0.01

    READ0=$(cat "${TSF_FILES[0]}")
    READ1=$(cat "${TSF_FILES[1]}")
    DIFF=$((READ1 - READ0))

    echo "  ${WLANS[0]}: $READ0 µs"
    echo "  ${WLANS[1]}: $READ1 µs"
    echo "  Difference: $DIFF µs"

    # Should be ~8,000,000 (8 seconds difference)
    if [ "$DIFF" -gt 7000000 ] && [ "$DIFF" -lt 9000000 ]; then
        pass "radios have independent TSF offsets (diff=${DIFF}µs ≈ 8s)"
    else
        fail "TSF offset independence: diff=$DIFF, expected ~8000000"
    fi
else
    echo "  Need ≥2 wlan interfaces, found ${#TSF_FILES[@]}"
fi

# --- Sysfs driver identification ---

echo ""
echo "--- Driver identification via sysfs ---"

for phy in /sys/class/ieee80211/phy*; do
    [ -d "$phy" ] || continue
    PHY_NAME=$(basename "$phy")
    DRIVER_LINK=$(readlink -f "$phy/device/driver" 2>/dev/null || echo "")

    if echo "$DRIVER_LINK" | grep -q "mac80211_hwsim"; then
        pass "$PHY_NAME: driver symlink resolves to mac80211_hwsim"
    else
        fail "$PHY_NAME: driver symlink is '$DRIVER_LINK'"
    fi
    break  # Only check one
done

# --- Check for PTP clocks (should NOT exist without tsf-ptp) ---

echo ""
echo "--- Verify no PTP clocks from hwsim alone ---"

HWSIM_PTP=0
for phy in /sys/class/ieee80211/phy*; do
    [ -d "$phy" ] || continue
    if [ -d "$phy/device/ptp" ]; then
        ((HWSIM_PTP++))
    fi
done

if [ "$HWSIM_PTP" -eq 0 ]; then
    pass "no PTP clocks from mac80211_hwsim (as expected — tsf-ptp will add them)"
else
    fail "found $HWSIM_PTP PTP clocks from hwsim (unexpected)"
fi

# --- Summary ---

echo ""
echo "=== Results: PASS=$PASS  FAIL=$FAIL ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

echo ""
echo "mac80211_hwsim TSF foundation is working."
echo "Next step: build and test the tsf-ptp kernel module."
