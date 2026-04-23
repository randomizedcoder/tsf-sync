#
# mt7925-tsf-test.nix — shell-application wrappers for the write-path
# diagnosis described in patches/net-next/mt76/0006.
#
# These scripts exercise the `tsf_set` debugfs knob on an mt7925 AP vif
# and observe the on-air beacon TSF from a monitor vif added alongside
# the AP on the SAME phy. Decides whether mt792x_set_tsf's write path
# reaches the on-chip TSF counter (the one that stamps beacon bodies)
# even though the LPON UTTR read mirror is not populated -- see
# docs/mt7925-tsf-findings.md for why this matters.
#
# Observer strategy: mt7925 is half-duplex and does NOT loop its own
# transmitted beacons back to a co-resident monitor vif on the same
# phy, so we use a sibling radio. On the l2 rig both wls1 (phy0) and
# wls2 (phy1) are configured on ch36 specifically so phy1 can host a
# secondary monitor vif (`mon1`) that inherits ch36 and hears phy0's
# beacons. The monitor vif is added alongside phy1's existing AP --
# hostapd-multi is never disturbed.
#
# Env-var overrides (l2-rig defaults shown):
#
#   TARGET_PHY     phy holding the AP we want to probe/write
#                  (default: phy0)
#   MONITOR_PHY    phy we add the monitor vif on. Must be a DIFFERENT
#                  phy than TARGET_PHY and must already be operating
#                  on the same channel (monitor vifs inherit the phy's
#                  current channel). (default: phy1)
#   MONITOR_IFACE  name of the monitor vif we add on MONITOR_PHY
#                  (default: mon1)
#   TEST_VALUE     u64 written to tsf_set in µs (default: 99999999999999)
#   DURATION       max seconds per tshark capture window (default: 3)
#   BEACONS        beacons to capture per window (default: 3)
#
# Usage:
#
#   sudo nix run .#mt7925-tsf-probe              # dump tsf_probe output
#   sudo nix run .#mt7925-tsf-set -- 1234        # echo value into tsf_set
#   sudo nix run .#mt7925-tsf-monitor-setup      # add mon0 on TARGET_PHY
#   sudo nix run .#mt7925-tsf-monitor-teardown   # remove mon0
#   sudo nix run .#mt7925-tsf-capture            # tshark beacons once
#   sudo nix run .#mt7925-tsf-test               # full BEFORE/WRITE/AFTER
#
{ pkgs }:

let
  # Shared env-var preamble + auto-discovery. Each script sources this.
  common = ''
    set -euo pipefail

    if [ "$(id -u)" -ne 0 ]; then
      echo "error: must run as root (sudo nix run .#...)" >&2
      exit 1
    fi

    TARGET_PHY=''${TARGET_PHY:-phy0}
    MONITOR_PHY=''${MONITOR_PHY:-phy1}
    MONITOR_IFACE=''${MONITOR_IFACE:-mon1}
    TEST_VALUE=''${TEST_VALUE:-99999999999999}
    DURATION=''${DURATION:-3}
    BEACONS=''${BEACONS:-3}

    if [ "$TARGET_PHY" = "$MONITOR_PHY" ]; then
      echo "error: TARGET_PHY and MONITOR_PHY must differ (mt7925 does not" >&2
      echo "       self-loop beacons to a co-resident monitor vif)." >&2
      exit 1
    fi

    # Prints "$mac $freq" for the AP vif on $1 (a phy name, e.g. phy0).
    discover_ap_on_phy() {
      iw dev | awk -v phy="''${1#phy}" '
        /^phy#/ { p = $0; sub(/phy#/, "", p); next }
        p == phy && /^[[:space:]]*addr / { mac = $2 }
        p == phy && /^[[:space:]]*channel / { freq = $3; sub(/\(/, "", freq) }
        p == phy && /^[[:space:]]*type AP/ { is_ap = 1 }
        END { if (is_ap && mac && freq) print mac, freq; else exit 1 }'
    }

    discover_target() {
      discover_ap_on_phy "$TARGET_PHY"
    }

    preflight_ap() {
      # Abort loudly if the target is not currently an AP. Protects against
      # running the capture path when hostapd has just restarted the vif.
      if ! discover_target >/dev/null 2>&1; then
        echo "error: no AP vif on $TARGET_PHY. Check with 'iw dev' and" >&2
        echo "       restart hostapd-multi if needed, then retry." >&2
        exit 1
      fi
    }

    preflight_monitor_phy() {
      # Abort if MONITOR_PHY is not on the same channel as TARGET_PHY --
      # a monitor vif inherits its phy's channel, so cross-channel phys
      # cannot observe each other.
      local tgt_freq mon_freq
      tgt_freq=$(discover_ap_on_phy "$TARGET_PHY" | awk '{print $2}')
      mon_freq=$(discover_ap_on_phy "$MONITOR_PHY" | awk '{print $2}')
      if [ -z "$mon_freq" ]; then
        echo "error: no AP vif on $MONITOR_PHY -- monitor vif would have no" >&2
        echo "       channel to inherit. Configure an AP on $MONITOR_PHY first." >&2
        exit 1
      fi
      if [ "$tgt_freq" != "$mon_freq" ]; then
        echo "error: $TARGET_PHY is on $tgt_freq MHz but $MONITOR_PHY is on" >&2
        echo "       $mon_freq MHz. They must share a channel -- adjust" >&2
        echo "       hostapd-multi.nix so both phys are co-channel." >&2
        exit 1
      fi
    }
  '';

  runtimeDeps = with pkgs; [ iw iproute2 wireshark-cli coreutils gawk gnugrep ];
in
{
  # Dump /sys/kernel/debug/ieee80211/$TARGET_PHY/mt76/tsf_probe.
  mt7925-tsf-probe = pkgs.writeShellApplication {
    name = "mt7925-tsf-probe";
    runtimeInputs = runtimeDeps;
    text = common + ''
      PROBE="/sys/kernel/debug/ieee80211/''${TARGET_PHY}/mt76/tsf_probe"
      if [ ! -r "$PROBE" ]; then
        echo "error: $PROBE not found -- is patch 0005 applied?" >&2
        exit 1
      fi
      cat "$PROBE"
    '';
  };

  # Write $1 (or $TEST_VALUE) to tsf_set.
  mt7925-tsf-set = pkgs.writeShellApplication {
    name = "mt7925-tsf-set";
    runtimeInputs = runtimeDeps;
    text = common + ''
      VAL=''${1:-$TEST_VALUE}
      SETF="/sys/kernel/debug/ieee80211/''${TARGET_PHY}/mt76/tsf_set"
      if [ ! -w "$SETF" ]; then
        echo "error: $SETF not writable -- is patch 0006 applied?" >&2
        exit 1
      fi
      echo "==> writing $VAL to $SETF"
      printf '%s\n' "$VAL" > "$SETF"
      echo "==> OK"
    '';
  };

  # Add $MONITOR_IFACE as a second vif on $MONITOR_PHY (sibling radio,
  # co-channel with $TARGET_PHY). The monitor vif inherits its phy's
  # current channel, so it sees $TARGET_PHY's beacons without anyone
  # changing channel. Does NOT touch any AP or hostapd.
  mt7925-tsf-monitor-setup = pkgs.writeShellApplication {
    name = "mt7925-tsf-monitor-setup";
    runtimeInputs = runtimeDeps;
    text = common + ''
      preflight_ap
      preflight_monitor_phy
      read -r TARGET_MAC TARGET_FREQ < <(discover_target)
      echo "==> target AP : $TARGET_PHY mac=$TARGET_MAC freq=$TARGET_FREQ MHz"
      echo "==> monitor phy: $MONITOR_PHY (sibling, co-channel)"

      if iw dev "$MONITOR_IFACE" info >/dev/null 2>&1; then
        echo "==> $MONITOR_IFACE already exists, reusing"
      else
        echo "==> iw phy $MONITOR_PHY interface add $MONITOR_IFACE type monitor"
        if ! iw phy "$MONITOR_PHY" interface add "$MONITOR_IFACE" type monitor 2>&1; then
          echo "error: adding monitor vif on $MONITOR_PHY failed" >&2
          echo "       mt7925 firmware may not allow concurrent AP+monitor on one phy." >&2
          exit 1
        fi
      fi

      echo "==> ip link set $MONITOR_IFACE up"
      ip link set "$MONITOR_IFACE" up
      echo "==> $MONITOR_IFACE ready (inherits $MONITOR_PHY channel)"
      iw dev "$MONITOR_IFACE" info | sed 's/^/    /'
    '';
  };

  mt7925-tsf-monitor-teardown = pkgs.writeShellApplication {
    name = "mt7925-tsf-monitor-teardown";
    runtimeInputs = runtimeDeps;
    text = common + ''
      if iw dev "$MONITOR_IFACE" info >/dev/null 2>&1; then
        ip link set "$MONITOR_IFACE" down 2>/dev/null || true
        iw dev "$MONITOR_IFACE" del
        echo "==> $MONITOR_IFACE removed"
      else
        echo "==> $MONITOR_IFACE not present, nothing to do"
      fi
    '';
  };

  # Capture $BEACONS beacons from the target BSSID via $MONITOR_IFACE.
  # tshark stderr is preserved so capture failures are visible.
  mt7925-tsf-capture = pkgs.writeShellApplication {
    name = "mt7925-tsf-capture";
    runtimeInputs = runtimeDeps;
    text = common + ''
      preflight_ap
      read -r TARGET_MAC _TARGET_FREQ < <(discover_target)

      if ! iw dev "$MONITOR_IFACE" info >/dev/null 2>&1; then
        echo "error: $MONITOR_IFACE not present -- run mt7925-tsf-monitor-setup first" >&2
        exit 1
      fi

      echo "==> capture ($BEACONS beacons, max ''${DURATION}s) from $TARGET_MAC via $MONITOR_IFACE"
      tshark -i "$MONITOR_IFACE" -n -l \
        -Y "wlan.fc.type_subtype == 0x08 && wlan.bssid == $TARGET_MAC" \
        -T fields -e frame.time_relative -e wlan.bssid -e wlan.fixed.timestamp \
        -c "$BEACONS" -a "duration:$DURATION"
    '';
  };

  # End-to-end: add monitor, capture BEFORE, write TEST_VALUE, capture
  # AFTER, teardown. Verdict is obvious from the two TSF columns:
  #
  #   AFTER jumps ~TEST_VALUE   => write path reaches on-chip TSF.
  #   AFTER ≈ BEFORE + 100ms    => write path is also dead silicon.
  mt7925-tsf-test = pkgs.writeShellApplication {
    name = "mt7925-tsf-test";
    runtimeInputs = runtimeDeps;
    text = common + ''
      preflight_ap
      preflight_monitor_phy
      read -r TARGET_MAC TARGET_FREQ < <(discover_target)
      SETF="/sys/kernel/debug/ieee80211/''${TARGET_PHY}/mt76/tsf_set"

      if [ ! -w "$SETF" ]; then
        echo "error: $SETF not writable -- is patch 0006 applied?" >&2
        exit 1
      fi

      echo "=================================================================="
      echo "  mt7925 TSF write-path diagnosis"
      echo "  target  : $TARGET_PHY ($TARGET_MAC @ $TARGET_FREQ MHz)"
      echo "  monitor : $MONITOR_IFACE on $MONITOR_PHY (sibling, co-channel)"
      echo "  value   : $TEST_VALUE"
      echo "=================================================================="

      cleanup() {
        echo ""
        echo "==> teardown"
        ip link set "$MONITOR_IFACE" down 2>/dev/null || true
        iw dev "$MONITOR_IFACE" del 2>/dev/null || true
      }
      trap cleanup EXIT

      if iw dev "$MONITOR_IFACE" info >/dev/null 2>&1; then
        echo "==> $MONITOR_IFACE already exists, reusing"
      else
        if ! iw phy "$MONITOR_PHY" interface add "$MONITOR_IFACE" type monitor 2>&1; then
          echo "error: adding monitor vif failed" >&2
          exit 1
        fi
      fi
      ip link set "$MONITOR_IFACE" up

      echo ""
      echo "=== BEFORE ==="
      tshark -i "$MONITOR_IFACE" -n -l \
        -Y "wlan.fc.type_subtype == 0x08 && wlan.bssid == $TARGET_MAC" \
        -T fields -e frame.time_relative -e wlan.bssid -e wlan.fixed.timestamp \
        -c "$BEACONS" -a "duration:$DURATION"

      echo ""
      echo "=== WRITE $TEST_VALUE -> $SETF ==="
      printf '%s\n' "$TEST_VALUE" > "$SETF"

      echo ""
      echo "=== AFTER ==="
      tshark -i "$MONITOR_IFACE" -n -l \
        -Y "wlan.fc.type_subtype == 0x08 && wlan.bssid == $TARGET_MAC" \
        -T fields -e frame.time_relative -e wlan.bssid -e wlan.fixed.timestamp \
        -c "$BEACONS" -a "duration:$DURATION"

      echo ""
      echo "=== tsf_probe (read path, known-dead; for completeness) ==="
      cat "/sys/kernel/debug/ieee80211/''${TARGET_PHY}/mt76/tsf_probe" || true
    '';
  };
}
