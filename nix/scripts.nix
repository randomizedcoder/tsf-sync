{ pkgs, kernelModule, package }:

let
  # Runtime dependencies shared by test scripts.
  runtimeDeps = with pkgs; [ kmod linuxptp coreutils gnugrep gawk ];

  modulePath = "${kernelModule}/lib/modules/${pkgs.linuxPackages.kernel.modDirVersion}/extra/tsf_ptp.ko";
in
{
  # Quick smoke test: load hwsim + tsf-ptp, verify PTP clocks appear, check
  # adjtime threshold params, cleanup. Runs in ~5 seconds, requires root.
  #
  #   nix run .#test-hwsim
  #
  test-hwsim = pkgs.writeShellApplication {
    name = "tsf-sync-test-hwsim";
    runtimeInputs = runtimeDeps ++ [ package ];
    text = ''
      set -euo pipefail

      if [ "$(id -u)" -ne 0 ]; then
        echo "error: must run as root (sudo nix run .#test-hwsim)" >&2
        exit 1
      fi

      RADIOS=''${1:-4}
      THRESHOLD=''${2:-5000}

      cleanup() {
        echo "==> Cleaning up..."
        rmmod tsf_ptp 2>/dev/null || true
        rmmod mac80211_hwsim 2>/dev/null || true
      }
      trap cleanup EXIT

      echo "==> Loading mac80211_hwsim with $RADIOS radios"
      rmmod mac80211_hwsim 2>/dev/null || true
      modprobe mac80211_hwsim "radios=$RADIOS"
      sleep 0.5

      echo "==> Loading tsf-ptp (threshold=$THRESHOLD ns)"
      rmmod tsf_ptp 2>/dev/null || true
      insmod ${modulePath} "adjtime_threshold_ns=$THRESHOLD"
      sleep 0.5

      echo "==> Verifying module parameters"
      ACTUAL=$(cat /sys/module/tsf_ptp/parameters/adjtime_threshold_ns)
      if [ "$ACTUAL" != "$THRESHOLD" ]; then
        echo "FAIL: adjtime_threshold_ns expected $THRESHOLD, got $ACTUAL" >&2
        exit 1
      fi
      echo "   adjtime_threshold_ns = $ACTUAL"
      echo "   adjtime_skip_count   = $(cat /sys/module/tsf_ptp/parameters/adjtime_skip_count)"
      echo "   adjtime_apply_count  = $(cat /sys/module/tsf_ptp/parameters/adjtime_apply_count)"

      echo "==> Running discovery"
      tsf-sync discover

      # Count hwsim cards with PTP clocks.
      PTP_COUNT=$(find /sys/class/ieee80211/*/device/ptp -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
      if [ "$PTP_COUNT" -lt "$RADIOS" ]; then
        echo "FAIL: expected $RADIOS PTP clocks, found $PTP_COUNT" >&2
        exit 1
      fi
      echo "   PTP clocks registered: $PTP_COUNT"

      echo "==> Testing adjtime threshold (phc_ctl adj)"
      # Small adj below threshold — should be skipped.
      phc_ctl /dev/ptp1 -- adj 0.000001 2>/dev/null  # 1000 ns
      SKIP=$(cat /sys/module/tsf_ptp/parameters/adjtime_skip_count)
      if [ "$SKIP" -lt 1 ]; then
        echo "FAIL: expected skip_count >= 1 after sub-threshold adj, got $SKIP" >&2
        exit 1
      fi
      echo "   Sub-threshold adj: skip_count = $SKIP (OK)"

      # Large adj above threshold — should be applied.
      phc_ctl /dev/ptp1 -- adj 0.00001 2>/dev/null  # 10000 ns
      APPLY=$(cat /sys/module/tsf_ptp/parameters/adjtime_apply_count)
      if [ "$APPLY" -lt 1 ]; then
        echo "FAIL: expected apply_count >= 1 after above-threshold adj, got $APPLY" >&2
        exit 1
      fi
      echo "   Above-threshold adj: apply_count = $APPLY (OK)"

      echo "==> Testing runtime threshold change"
      echo 0 > /sys/module/tsf_ptp/parameters/adjtime_threshold_ns
      ACTUAL=$(cat /sys/module/tsf_ptp/parameters/adjtime_threshold_ns)
      if [ "$ACTUAL" != "0" ]; then
        echo "FAIL: runtime threshold change failed, got $ACTUAL" >&2
        exit 1
      fi
      echo "   Runtime change to 0: OK"
      echo "$THRESHOLD" > /sys/module/tsf_ptp/parameters/adjtime_threshold_ns

      echo ""
      echo "All tests passed."
    '';
  };

  # Integration test: run phc2sys sync for a configurable duration and report
  # counter stats. Useful for observing sync behavior over time.
  #
  #   sudo nix run .#test-sync -- [duration_secs] [threshold_ns]
  #
  test-sync = pkgs.writeShellApplication {
    name = "tsf-sync-test-sync";
    runtimeInputs = runtimeDeps ++ [ package ];
    text = ''
      set -euo pipefail

      if [ "$(id -u)" -ne 0 ]; then
        echo "error: must run as root (sudo nix run .#test-sync)" >&2
        exit 1
      fi

      DURATION=''${1:-30}
      THRESHOLD=''${2:-5000}
      RADIOS=4

      cleanup() {
        echo ""
        echo "==> Stopping sync processes..."
        kill "$SYNC_PID" 2>/dev/null || true
        wait "$SYNC_PID" 2>/dev/null || true
        echo "==> Final counters:"
        echo "   adjtime_skip_count  = $(cat /sys/module/tsf_ptp/parameters/adjtime_skip_count 2>/dev/null || echo N/A)"
        echo "   adjtime_apply_count = $(cat /sys/module/tsf_ptp/parameters/adjtime_apply_count 2>/dev/null || echo N/A)"
        echo "==> Cleaning up..."
        rmmod tsf_ptp 2>/dev/null || true
        rmmod mac80211_hwsim 2>/dev/null || true
      }
      trap cleanup EXIT

      SYNC_PID=""

      echo "==> Loading mac80211_hwsim with $RADIOS radios"
      rmmod mac80211_hwsim 2>/dev/null || true
      modprobe mac80211_hwsim "radios=$RADIOS"
      sleep 0.5

      echo "==> Loading tsf-ptp (threshold=$THRESHOLD ns)"
      rmmod tsf_ptp 2>/dev/null || true
      insmod ${modulePath} "adjtime_threshold_ns=$THRESHOLD"
      sleep 0.5

      echo "==> Starting tsf-sync (will run for $DURATION seconds)"
      tsf-sync start --adjtime-threshold-ns "$THRESHOLD" &
      SYNC_PID=$!

      echo "==> Monitoring counters every 5 seconds..."
      ELAPSED=0
      while [ "$ELAPSED" -lt "$DURATION" ]; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        SKIP=$(cat /sys/module/tsf_ptp/parameters/adjtime_skip_count)
        APPLY=$(cat /sys/module/tsf_ptp/parameters/adjtime_apply_count)
        echo "   [$ELAPSED s] skip=$SKIP apply=$APPLY"
      done
    '';
  };

  # Build the kernel module from the current (possibly dirty) working tree.
  # Useful during development when nix build caches stale results.
  #
  #   nix run .#build-kernel-module
  #
  build-kernel-module = pkgs.writeShellApplication {
    name = "tsf-sync-build-kernel-module";
    runtimeInputs = with pkgs; [ gnumake ];
    text = ''
      set -euo pipefail
      KDIR="${pkgs.linuxPackages.kernel.dev}/lib/modules/${pkgs.linuxPackages.kernel.modDirVersion}/build"

      echo "==> Cleaning kernel build artifacts"
      cd kernel
      rm -f .*.cmd *.o *.ko *.mod *.mod.c Module.symvers modules.order

      echo "==> Building tsf_ptp.ko (KDIR=$KDIR)"
      make "KDIR=$KDIR"

      echo ""
      echo "Built: kernel/tsf_ptp.ko"
      modinfo tsf_ptp.ko
    '';
  };
}
