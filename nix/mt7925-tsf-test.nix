#
# mt7925-tsf-test.nix — shell-application wrappers for the write-path
# diagnosis described in patches/net-next/mt76/0006.
#
# These scripts exercise the `tsf_set` debugfs knob on an mt7925 AP vif
# and observe the on-air beacon TSF from a second radio put briefly into
# monitor mode. Decides whether mt792x_set_tsf's write path reaches the
# on-chip TSF counter (the one that stamps beacon bodies) even though
# the LPON UTTR read mirror is not populated -- see
# docs/mt7925-tsf-findings.md for why this matters.
#
# All scripts default to the l2 test-rig layout (target=phy0, observer=
# phy1) but accept overrides via env vars so they work on other rigs:
#
#   TARGET_PHY     phy holding the AP whose TSF we want to probe/write
#                  (default: phy0)
#   OBSERVER_PHY   phy we temporarily repurpose as a monitor
#                  (default: phy1)
#   TEST_VALUE     u64 written to tsf_set in µs (default: 99999999999999)
#   DURATION       seconds per tshark capture window (default: 3)
#   BEACONS        beacons to capture per window (default: 3)
#
# The target MAC, channel and observer-AP interface name are auto-
# discovered from `iw dev`, so the only invariant is that $TARGET_PHY
# has a live AP and $OBSERVER_PHY has something we are allowed to tear
# down.
#
# Usage:
#
#   sudo nix run .#mt7925-tsf-probe              # dump tsf_probe output
#   sudo nix run .#mt7925-tsf-set -- 1234        # echo value into tsf_set
#   sudo nix run .#mt7925-tsf-monitor-setup      # bring up monitor mon1
#   sudo nix run .#mt7925-tsf-monitor-teardown   # tear it down
#   sudo nix run .#mt7925-tsf-capture            # capture beacons once
#   sudo nix run .#mt7925-tsf-test               # full before/write/after
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
    OBSERVER_PHY=''${OBSERVER_PHY:-phy1}
    MONITOR_IFACE=''${MONITOR_IFACE:-mon1}
    TEST_VALUE=''${TEST_VALUE:-99999999999999}
    DURATION=''${DURATION:-3}
    BEACONS=''${BEACONS:-3}

    discover_target() {
      # Prints "$mac $freq" for the AP vif on $TARGET_PHY.
      iw dev | awk -v phy="''${TARGET_PHY#phy}" '
        /^phy#/ { p = $0; sub(/phy#/, "", p); next }
        p == phy && /^[[:space:]]*addr / { mac = $2 }
        p == phy && /^[[:space:]]*channel / { freq = $3; sub(/\(/, "", freq) }
        p == phy && /^[[:space:]]*type AP/ { is_ap = 1 }
        END { if (is_ap && mac && freq) print mac, freq; else exit 1 }'
    }

    discover_observer_iface() {
      # Prints the first interface name on $OBSERVER_PHY.
      iw dev | awk -v phy="''${OBSERVER_PHY#phy}" '
        /^phy#/ { p = $0; sub(/phy#/, "", p); next }
        p == phy && /^[[:space:]]*Interface / { print $2; exit }'
    }
  '';

  runtimeDeps = with pkgs; [ iw iproute2 wireshark-cli coreutils gawk gnugrep ];
in
{
  # Dump /sys/kernel/debug/ieee80211/$TARGET_PHY/mt76/tsf_probe (if
  # patch 0005 is applied). Convenient wrapper -- tsf_probe is what
  # patch 0005 registered and is read-only.
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

  # Write $1 (or $TEST_VALUE) to tsf_set. The file appears only if
  # patch 0006 is applied.
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

  # Repurpose $OBSERVER_PHY as a monitor vif on $TARGET_PHY's channel.
  # Tears down whatever interface $OBSERVER_PHY is currently hosting.
  mt7925-tsf-monitor-setup = pkgs.writeShellApplication {
    name = "mt7925-tsf-monitor-setup";
    runtimeInputs = runtimeDeps;
    text = common + ''
      read -r TARGET_MAC TARGET_FREQ < <(discover_target)
      echo "==> target: $TARGET_PHY mac=$TARGET_MAC freq=$TARGET_FREQ MHz"

      OBS_IFACE=$(discover_observer_iface || true)
      if [ -n "$OBS_IFACE" ] && [ "$OBS_IFACE" != "$MONITOR_IFACE" ]; then
        echo "==> tearing down $OBS_IFACE on $OBSERVER_PHY"
        ip link set "$OBS_IFACE" down 2>/dev/null || true
        iw dev "$OBS_IFACE" del 2>/dev/null || true
      fi

      if iw dev "$MONITOR_IFACE" info >/dev/null 2>&1; then
        echo "==> $MONITOR_IFACE already exists, leaving it"
      else
        echo "==> creating $MONITOR_IFACE on $OBSERVER_PHY"
        iw phy "$OBSERVER_PHY" interface add "$MONITOR_IFACE" type monitor
      fi

      ip link set "$MONITOR_IFACE" up
      iw dev "$MONITOR_IFACE" set freq "$TARGET_FREQ"
      echo "==> $MONITOR_IFACE up on $TARGET_FREQ MHz"
    '';
  };

  # Remove $MONITOR_IFACE. Does not restore the sacrificed AP vif --
  # a rebuild/reboot or hostapd-multi restart does that.
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

  # Capture $BEACONS beacons from the target BSSID via $MONITOR_IFACE
  # and print two columns: frame.time_relative, beacon-body TSF (µs).
  # wlan.fixed.timestamp is stamped by the transmitter's hardware at
  # TX time, so it reflects the on-chip TSF counter of $TARGET_PHY.
  mt7925-tsf-capture = pkgs.writeShellApplication {
    name = "mt7925-tsf-capture";
    runtimeInputs = runtimeDeps;
    text = common + ''
      read -r TARGET_MAC _TARGET_FREQ < <(discover_target)

      if ! iw dev "$MONITOR_IFACE" info >/dev/null 2>&1; then
        echo "error: $MONITOR_IFACE not present -- run mt7925-tsf-monitor-setup first" >&2
        exit 1
      fi

      echo "==> capture ($BEACONS beacons, max ''${DURATION}s) from $TARGET_MAC"
      tshark -i "$MONITOR_IFACE" -I -n -l \
        -Y "wlan.fc.type_subtype == 0x08 && wlan.bssid == $TARGET_MAC" \
        -T fields -e frame.time_relative -e wlan.fixed.timestamp \
        -c "$BEACONS" -a "duration:$DURATION" 2>/dev/null
    '';
  };

  # End-to-end: setup monitor, capture BEFORE, write TEST_VALUE, capture
  # AFTER, teardown. Printable diff makes the verdict obvious:
  #
  #   - AFTER jumps to ~TEST_VALUE  => write path reaches on-chip TSF.
  #   - AFTER continues from BEFORE => write path is also dead silicon.
  mt7925-tsf-test = pkgs.writeShellApplication {
    name = "mt7925-tsf-test";
    runtimeInputs = runtimeDeps;
    text = common + ''
      read -r TARGET_MAC TARGET_FREQ < <(discover_target)
      SETF="/sys/kernel/debug/ieee80211/''${TARGET_PHY}/mt76/tsf_set"

      if [ ! -w "$SETF" ]; then
        echo "error: $SETF not writable -- is patch 0006 applied?" >&2
        exit 1
      fi

      echo "=================================================================="
      echo "  mt7925 TSF write-path diagnosis"
      echo "  target : $TARGET_PHY ($TARGET_MAC @ $TARGET_FREQ MHz)"
      echo "  observer: $OBSERVER_PHY -> $MONITOR_IFACE"
      echo "  value  : $TEST_VALUE"
      echo "=================================================================="

      # setup (inline -- we want one trap)
      OBS_IFACE=$(discover_observer_iface || true)
      cleanup() {
        echo ""
        echo "==> teardown"
        ip link set "$MONITOR_IFACE" down 2>/dev/null || true
        iw dev "$MONITOR_IFACE" del 2>/dev/null || true
      }
      trap cleanup EXIT

      if [ -n "$OBS_IFACE" ] && [ "$OBS_IFACE" != "$MONITOR_IFACE" ]; then
        ip link set "$OBS_IFACE" down 2>/dev/null || true
        iw dev "$OBS_IFACE" del 2>/dev/null || true
      fi
      iw phy "$OBSERVER_PHY" interface add "$MONITOR_IFACE" type monitor
      ip link set "$MONITOR_IFACE" up
      iw dev "$MONITOR_IFACE" set freq "$TARGET_FREQ"

      echo ""
      echo "=== BEFORE ==="
      tshark -i "$MONITOR_IFACE" -I -n -l \
        -Y "wlan.fc.type_subtype == 0x08 && wlan.bssid == $TARGET_MAC" \
        -T fields -e frame.time_relative -e wlan.fixed.timestamp \
        -c "$BEACONS" -a "duration:$DURATION" 2>/dev/null

      echo ""
      echo "=== WRITE $TEST_VALUE -> $SETF ==="
      printf '%s\n' "$TEST_VALUE" > "$SETF"

      echo ""
      echo "=== AFTER ==="
      tshark -i "$MONITOR_IFACE" -I -n -l \
        -Y "wlan.fc.type_subtype == 0x08 && wlan.bssid == $TARGET_MAC" \
        -T fields -e frame.time_relative -e wlan.fixed.timestamp \
        -c "$BEACONS" -a "duration:$DURATION" 2>/dev/null

      echo ""
      echo "=== tsf_probe (read path, known-dead; for completeness) ==="
      cat "/sys/kernel/debug/ieee80211/''${TARGET_PHY}/mt76/tsf_probe" || true
    '';
  };
}
