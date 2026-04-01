# Comprehensive benchmark harness: head-to-head comparison of ALL tsf-sync
# synchronization modes inside a microVM with mac80211_hwsim.
#
# Modes tested:
#   A  phc2sys     — PTP clock + phc2sys PI loop (tsf-sync start --sync_mode ptp)
#   B  kernel      — in-kernel delayed_work loop (tsf-sync start --sync_mode kernel)
#   C  io_uring    — batch read/write via /dev/tsf_sync (if iouring feature built)
#   D  Rust debugfs — pread/pwrite + SIMD + inline syscall (tsf-sync-debugfs)
#   E  C debugfs   — open/read/close per access (FiWiTSF tsf_sync_rt_starter)
#
# One VM, all modes, same radios, same duration, standardized metrics.
#
# Usage:
#   nix run .#tsf-sync-benchmark-4         # 4 radios, quick
#   nix run .#tsf-sync-benchmark-24        # 24 radios, production scale
#   nix run .#tsf-sync-benchmark-100       # 100 radios, stress test
#   nix run .#tsf-sync-benchmark-all       # all radio counts sequentially
{
  pkgs,
  lib,
  constants,
  mkMicrovm,
  microvmVariants,
}:
let
  lifecycleLib = import ../lifecycle/lib.nix { inherit pkgs lib; };

  inherit (lifecycleLib)
    colorHelpers
    timingHelpers
    processHelpers
    consoleHelpers
    commonInputs
    sshInputs
    ;

  sshHelpers = lifecycleLib.mkSshHelpers { sshPassword = constants.defaults.sshPassword; };

  # ─── Benchmark VM (extra packages for profiling) ───────────────────────────
  benchVm = mkMicrovm {
    arch = "x86_64";
    variant = "benchmark";
    inherit (constants.variants.benchmark) portOffset radios threshold syncMode;
    extraPackages = with pkgs; [
      strace
      time         # /usr/bin/time -v
    ];
  };

  arch = "x86_64";
  portOffset = constants.variants.benchmark.portOffset;
  archTimeouts = constants.getTimeouts arch;
  hostname = "tsf-sync-x86_64-benchmark-vm";
  sshForwardPort = constants.sshForwardPort arch portOffset;

  # ─── Shared metric-collection helpers (interpolated into scripts) ──────────

  # Run a sync command under strace -c, capture syscall summary.
  # Usage: run_with_metrics <label> <duration> <command...>
  metricsHelpers = ''
    RESULTS_DIR=$(mktemp -d)

    run_with_metrics() {
      local label="$1"
      local dur="$2"
      shift 2
      local cmd="$*"

      local strace_out="/tmp/''${label}_strace.out"
      local time_out="/tmp/''${label}_time.out"
      local sync_out="/tmp/''${label}_sync.out"

      bold "  [$label] Running for ''${dur}s: $cmd"

      # Collect strace syscall counts + /usr/bin/time stats.
      ssh_cmd "$SSH_HOST" "$SSH_PORT" "
        /usr/bin/time -v -o $time_out strace -c -o $strace_out \
          timeout $dur $cmd >$sync_out 2>&1;
        echo '---TIME---'
        cat $time_out 2>/dev/null || true
        echo '---STRACE---'
        cat $strace_out 2>/dev/null
        echo '---SYNC---'
        tail -5 $sync_out 2>/dev/null
      " >"$RESULTS_DIR/''${label}_raw.txt" 2>&1 || true

      # Also try perf stat if available.
      ssh_cmd "$SSH_HOST" "$SSH_PORT" "
        if command -v perf >/dev/null 2>&1; then
          perf stat -e cycles,instructions,context-switches \
            -- timeout $dur $cmd 2>&1 | tail -15
        fi
      " >"$RESULTS_DIR/''${label}_perf.txt" 2>&1 || true

      # Extract key metrics.
      local total_syscalls
      total_syscalls=$(ssh_cmd "$SSH_HOST" "$SSH_PORT" \
        "awk '\$NF!=\"syscall\" && \$NF!=\"total\" && !/^-/ && /^[[:space:]]*[0-9]/ {sum+=\$4} END{print sum+0}' $strace_out 2>/dev/null" 2>/dev/null || echo "N/A")

      local ctx_switches
      ctx_switches=$(ssh_cmd "$SSH_HOST" "$SSH_PORT" \
        "grep 'Voluntary context switches' $time_out 2>/dev/null | awk '{print \$NF}'" 2>/dev/null || echo "N/A")

      local max_rss
      max_rss=$(ssh_cmd "$SSH_HOST" "$SSH_PORT" \
        "grep 'Maximum resident' $time_out 2>/dev/null | awk '{print \$NF}'" 2>/dev/null || echo "N/A")

      # Store results for comparison table.
      echo "$label|$total_syscalls|$ctx_switches|$max_rss" >> "$RESULTS_DIR/summary.csv"

      info "  [$label] syscalls=$total_syscalls ctx=$ctx_switches rss=''${max_rss}KB"
    }

    # Read kernel module sysfs counters, print delta since last read.
    read_sysfs_counters() {
      ssh_cmd "$SSH_HOST" "$SSH_PORT" "
        echo \"skip=\$(cat /sys/module/tsf_ptp/parameters/adjtime_skip_count 2>/dev/null || echo N/A)\"
        echo \"apply=\$(cat /sys/module/tsf_ptp/parameters/adjtime_apply_count 2>/dev/null || echo N/A)\"
        echo \"sync=\$(cat /sys/module/tsf_ptp/parameters/sync_count 2>/dev/null || echo N/A)\"
      " 2>/dev/null || true
    }

    # Clean state between benchmark modes.
    clean_between() {
      ssh_cmd "$SSH_HOST" "$SSH_PORT" "
        killall tsf-sync tsf-sync-debugfs tsf_sync_rt_starter phc2sys 2>/dev/null || true
        sleep 1
        rmmod tsf_ptp 2>/dev/null || true
        sleep 1
      " 2>/dev/null || true
    }

    # Read TSF values from debugfs to check convergence.
    read_tsf_offsets() {
      ssh_cmd "$SSH_HOST" "$SSH_PORT" "
        MASTER_TSF=\$(cat $MASTER_PATH 2>/dev/null)
        echo \"master=\$MASTER_TSF\"
        for f in $FOLLOWER_PATHS; do
          F_TSF=\$(cat \$f 2>/dev/null)
          echo \"follower=\$F_TSF\"
        done
      " 2>/dev/null || true
    }
  '';

  # ─── Comparison table printer ──────────────────────────────────────────────
  printComparison = ''
    print_comparison() {
      echo ""
      bold "╔══════════════════════════════════════════════════════════════════╗"
      bold "║              BENCHMARK COMPARISON — $RADIOS radios             ║"
      bold "╠══════════════════╦════════════╦════════════╦════════════════════╣"
      bold "║ Mode             ║ Syscalls   ║ Ctx Switch ║ RSS (KB)           ║"
      bold "╠══════════════════╬════════════╬════════════╬════════════════════╣"

      while IFS='|' read -r label syscalls ctx rss; do
        printf "║ %-16s ║ %10s ║ %10s ║ %18s ║\n" "$label" "$syscalls" "$ctx" "$rss"
      done < "$RESULTS_DIR/summary.csv"

      bold "╚══════════════════╩════════════╩════════════╩════════════════════╝"
      echo ""

      # Also dump per-mode perf output if available.
      for f in "$RESULTS_DIR"/*_perf.txt; do
        if [[ -s "$f" ]]; then
          local mode
          mode=$(basename "$f" _perf.txt)
          bold "--- perf stat: $mode ---"
          cat "$f"
          echo ""
        fi
      done
    }
  '';

  # ─── Benchmark script generator ───────────────────────────────────────────
  mkBenchScript =
    name:
    { radios, duration, description }:
    pkgs.writeShellApplication {
      name = "tsf-sync-benchmark-${name}";
      runtimeInputs = commonInputs ++ sshInputs;
      text = ''
        set +e

        ${colorHelpers}
        ${timingHelpers}
        ${processHelpers}
        ${consoleHelpers}
        ${sshHelpers}
        ${metricsHelpers}
        ${printComparison}

        RADIOS=${toString radios}
        DURATION=${toString duration}

        bold "════════════════════════════════════════════════════════════════"
        bold "  tsf-sync Comprehensive Benchmark"
        bold "  ${description}"
        bold "  Radios: $RADIOS | Duration per mode: ''${DURATION}s"
        bold "════════════════════════════════════════════════════════════════"
        echo ""
        bold "  Modes: A(phc2sys) B(kernel) C(io_uring) D(Rust debugfs) E(C debugfs)"
        echo ""

        # ─── Phase 0: Boot VM ─────────────────────────────────────────
        bold "--- Phase 0: Boot VM ---"
        if vm_is_running "${hostname}"; then
          warn "  Killing existing VM..."
          kill_vm "${hostname}"
          sleep 2
        fi

        ${benchVm.runner}/bin/microvm-run &
        VM_BG_PID=$!

        cleanup() {
          kill_vm "${hostname}" 2>/dev/null || true
          wait "$VM_BG_PID" 2>/dev/null || true
        }
        trap cleanup EXIT

        if ! wait_for_process "${hostname}" ${toString archTimeouts.start}; then
          error "VM process not found"
          exit 1
        fi

        bold "--- Phase 0b: Wait for SSH ---"
        if ! wait_for_ssh "localhost" "${toString sshForwardPort}" ${toString archTimeouts.ssh}; then
          error "SSH not available"
          exit 1
        fi

        SSH_HOST="localhost"
        SSH_PORT="${toString sshForwardPort}"

        # ─── Phase 1: Setup hwsim ────────────────────────────────────
        bold "--- Phase 1: Load mac80211_hwsim ($RADIOS radios) ---"
        ssh_cmd "$SSH_HOST" "$SSH_PORT" "modprobe mac80211_hwsim radios=$RADIOS"
        sleep 2

        # Bring up interfaces (needed for debugfs paths to appear).
        ssh_cmd "$SSH_HOST" "$SSH_PORT" "
          for i in \$(seq 0 \$(($RADIOS - 1))); do
            ip link set wlan\$i up 2>/dev/null || true
          done
        " 2>/dev/null || true
        sleep 1

        # ─── Phase 2: Discover paths ─────────────────────────────────
        bold "--- Phase 2: Discover debugfs TSF paths ---"
        PATHS=$(ssh_cmd "$SSH_HOST" "$SSH_PORT" \
          'ls /sys/kernel/debug/ieee80211/phy*/netdev:wlan*/tsf 2>/dev/null | sort')

        MASTER_PATH=$(echo "$PATHS" | head -1)
        FOLLOWER_PATHS=$(echo "$PATHS" | tail -n +2)
        FOLLOWER_COUNT=$(echo "$FOLLOWER_PATHS" | wc -l)

        info "  Master:    $MASTER_PATH"
        info "  Followers: $FOLLOWER_COUNT"

        if [[ -z "$MASTER_PATH" ]] || [[ "$FOLLOWER_COUNT" -eq 0 ]]; then
          error "Could not discover TSF paths"
          exit 1
        fi

        # Build -f flags for debugfs binaries.
        FOLLOWER_FLAGS=""
        while IFS= read -r fpath; do
          [[ -n "$fpath" ]] && FOLLOWER_FLAGS="$FOLLOWER_FLAGS -f $fpath"
        done <<< "$FOLLOWER_PATHS"

        # ═══════════════════════════════════════════════════════════════
        # Mode A: phc2sys (PTP clock + userspace PI loop)
        # ═══════════════════════════════════════════════════════════════
        bold ""
        bold "━━━ Mode A: phc2sys (PTP clock + PI loop) ━━━"
        ssh_cmd "$SSH_HOST" "$SSH_PORT" \
          "modprobe tsf_ptp adjtime_threshold_ns=5000 sync_mode=0 2>/dev/null || true"
        sleep 1

        run_with_metrics "A_phc2sys" "$DURATION" \
          "tsf-sync start --primary auto --sync_mode ptp"

        info "  Kernel counters:"
        read_sysfs_counters
        clean_between

        # ═══════════════════════════════════════════════════════════════
        # Mode B: kernel sync (in-kernel delayed_work loop)
        # ═══════════════════════════════════════════════════════════════
        bold ""
        bold "━━━ Mode B: kernel sync (in-kernel loop) ━━━"
        ssh_cmd "$SSH_HOST" "$SSH_PORT" \
          "modprobe tsf_ptp adjtime_threshold_ns=5000 sync_mode=1 sync_interval_ms=10 2>/dev/null || true"
        sleep 1

        # Mode B runs entirely in kernel — measure by just sleeping and
        # reading sysfs counters. Run tsf-sync in monitoring-only mode.
        run_with_metrics "B_kernel" "$DURATION" \
          "tsf-sync start --primary auto --sync_mode kernel --sync_interval_ms 10"

        info "  Kernel counters:"
        read_sysfs_counters
        clean_between

        # ═══════════════════════════════════════════════════════════════
        # Mode C: io_uring (batch syscalls via /dev/tsf_sync)
        # ═══════════════════════════════════════════════════════════════
        bold ""
        bold "━━━ Mode C: io_uring (batch I/O) ━━━"

        if ssh_cmd "$SSH_HOST" "$SSH_PORT" "tsf-sync start --help 2>&1 | grep -q iouring" 2>/dev/null; then
          ssh_cmd "$SSH_HOST" "$SSH_PORT" \
            "modprobe tsf_ptp adjtime_threshold_ns=5000 sync_mode=0 2>/dev/null || true"
          sleep 1

          run_with_metrics "C_iouring" "$DURATION" \
            "tsf-sync start --primary auto --sync_mode iouring"

          info "  Kernel counters:"
          read_sysfs_counters
          clean_between
        else
          warn "  SKIP: io_uring mode not available (binary not built with --features iouring)"
          echo "C_iouring|SKIP|SKIP|SKIP" >> "$RESULTS_DIR/summary.csv"
        fi

        # ═══════════════════════════════════════════════════════════════
        # Mode D: Rust debugfs (pread/pwrite + SIMD + inline syscall)
        # ═══════════════════════════════════════════════════════════════
        bold ""
        bold "━━━ Mode D: Rust debugfs (pread/pwrite + SIMD) ━━━"

        run_with_metrics "D_rust_dbg" "$DURATION" \
          "tsf-sync-debugfs -m $MASTER_PATH $FOLLOWER_FLAGS -p 10 -u 5"

        read_tsf_offsets
        clean_between

        # ═══════════════════════════════════════════════════════════════
        # Mode E: C debugfs — FiWiTSF (open/read/close per access)
        # ═══════════════════════════════════════════════════════════════
        bold ""
        bold "━━━ Mode E: C debugfs — FiWiTSF (open/read/close) ━━━"

        if ssh_cmd "$SSH_HOST" "$SSH_PORT" "command -v tsf_sync_rt_starter" >/dev/null 2>&1; then
          run_with_metrics "E_c_debugfs" "$DURATION" \
            "tsf_sync_rt_starter -m $MASTER_PATH $FOLLOWER_FLAGS -p 10 -u 5"

          read_tsf_offsets
          clean_between
        else
          warn "  SKIP: FiWiTSF (tsf_sync_rt_starter) not installed in VM"
          warn "  To enable: update hash in bench/fiwitsf.nix and add to VM packages"
          echo "E_c_debugfs|SKIP|SKIP|SKIP" >> "$RESULTS_DIR/summary.csv"
        fi

        # ═══════════════════════════════════════════════════════════════
        # Comparison
        # ═══════════════════════════════════════════════════════════════
        print_comparison

        # ─── Shutdown ─────────────────────────────────────────────────
        bold "--- Shutdown ---"
        ssh_cmd "$SSH_HOST" "$SSH_PORT" "systemctl reboot" 2>/dev/null || true

        if ! wait_for_exit "${hostname}" 30; then
          kill_vm "${hostname}" 2>/dev/null || true
        fi

        trap - EXIT
        wait "$VM_BG_PID" 2>/dev/null || true

        bold "Benchmark complete."
      '';
    };

  benchVariants = {
    "4" = {
      radios = 4;
      duration = 30;
      description = "4 radios — baseline quick benchmark";
    };
    "24" = {
      radios = 24;
      duration = 60;
      description = "24 radios — current hardware scale";
    };
    "100" = {
      radios = 100;
      duration = 60;
      description = "100 radios — stress test";
    };
  };

  benchTests = lib.mapAttrs mkBenchScript benchVariants;

  benchAll = pkgs.writeShellApplication {
    name = "tsf-sync-benchmark-all";
    runtimeInputs = commonInputs;
    text = let
      names = builtins.attrNames benchTests;
    in ''
      set +e
      ${lib.concatMapStringsSep "\n" (name: ''
        echo ""
        echo "════════════════════════════════════════"
        echo "  Running: benchmark-${name}"
        echo "════════════════════════════════════════"
        ${benchTests.${name}}/bin/tsf-sync-benchmark-${name} || true
      '') names}
      echo ""
      echo "All benchmarks complete."
    '';
  };

in
{
  packages =
    lib.mapAttrs' (
      name: pkg: lib.nameValuePair "tsf-sync-benchmark-${name}" pkg
    ) benchTests
    // {
      tsf-sync-benchmark-all = benchAll;
    };
}
