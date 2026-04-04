# Entry point for tsf-sync MicroVM lifecycle testing.
# Generates lifecycle test scripts for all MicroVM variants across architectures.
#
# Generated outputs:
#   tsf-sync-lifecycle-test-<arch>-<variant>  - Full lifecycle test per arch+variant
#   tsf-sync-lifecycle-test-<variant>          - Backwards-compat alias (x86_64)
#   tsf-sync-lifecycle-test-all               - Test all variants sequentially
#
{
  pkgs,
  lib,
  constants,
  mkMicrovm,
  microvmVariants,
}:
let
  lifecycleLib = import ./lib.nix { inherit pkgs lib; };
  tsfChecks = import ./tsf-sync-checks.nix { inherit lib; };

  inherit (lifecycleLib)
    colorHelpers
    timingHelpers
    processHelpers
    consoleHelpers
    commonInputs
    sshInputs
    tsfSyncHelpers
    ;

  sshHelpers = lifecycleLib.mkSshHelpers { sshPassword = constants.defaults.sshPassword; };

  # ─── Shared preamble (helpers + counters) and summary footer ──────────
  testPreamble = ''
    set +e

    ${colorHelpers}
    ${timingHelpers}
    ${processHelpers}
    ${consoleHelpers}
    ${sshHelpers}
    ${tsfSyncHelpers}

    TOTAL_START=$(time_ms)
    TOTAL_PASSED=0
    TOTAL_FAILED=0

    record_pass() { TOTAL_PASSED=$((TOTAL_PASSED + 1)); }
    record_fail() { TOTAL_FAILED=$((TOTAL_FAILED + 1)); }
  '';

  testSummary =
    { label, detail }:
    ''
      TOTAL_ELAPSED=$(elapsed_ms "$TOTAL_START")

      echo ""
      bold "========================================"
      if [[ $TOTAL_FAILED -eq 0 ]]; then
        success "  ${label} ($TOTAL_PASSED checks)"
        success "  ${detail}"
        success "  Total time: $(format_ms "$TOTAL_ELAPSED")"
      else
        error "  $TOTAL_FAILED PHASES FAILED ($TOTAL_PASSED passed)"
        error "  ${detail}"
      fi
      bold "========================================"

      [[ $TOTAL_FAILED -eq 0 ]]
    '';

  # ─── Full lifecycle test for a variant on a specific architecture ───────
  mkFullTest =
    arch: variantName:
    let
      variantConfig = constants.variants.${variantName};
      portOffset = variantConfig.portOffset;
      archCfg = constants.architectures.${arch};
      archTimeouts = constants.getTimeouts arch;
      hostname = "tsf-sync-${arch}-${variantName}-vm";
      consolePorts = constants.consolePorts arch portOffset;
      sshForwardPort = constants.sshForwardPort arch portOffset;
      vm = microvmVariants."${arch}-${variantName}";

      radios = variantConfig.radios;
      threshold = variantConfig.threshold;
      syncMode = variantConfig.syncMode;
      hasSelftest = variantConfig ? selftestDuration;
      selftestDuration = variantConfig.selftestDuration or 60;
    in
    pkgs.writeShellApplication {
      name = "tsf-sync-lifecycle-test-${arch}-${variantName}";
      runtimeInputs = commonInputs ++ sshInputs;
      text = ''
        ${testPreamble}

        # Configuration
        VARIANT="${variantName}"
        ARCH="${arch}"
        HOSTNAME="${hostname}"
        SERIAL_PORT=${toString consolePorts.serial}
        VIRTIO_PORT=${toString consolePorts.virtio}
        SSH_HOST="localhost"
        SSH_PORT=${toString sshForwardPort}

        bold "========================================"
        bold "  tsf-sync MicroVM Lifecycle Test"
        bold "  Variant: $VARIANT | Arch: $ARCH"
        bold "  ${archCfg.description}"
        bold "  Radios: ${toString radios} | Threshold: ${toString threshold}ns"
        bold "========================================"
        echo ""

        # ─── Phase 0: Build VM ─────────────────────────────────────────
        phase_header "0" "Build VM" "${toString archTimeouts.build}"
        info "  VM already built via Nix closure."
        result_pass "VM built" "0"
        record_pass

        # ─── Phase 1: Start VM ────────────────────────────────────────
        phase_header "1" "Start VM ($ARCH)" "${toString archTimeouts.start}"
        start_time=$(time_ms)

        if vm_is_running "$HOSTNAME"; then
          warn "  Killing existing VM..."
          kill_vm "$HOSTNAME"
          sleep 2
        fi

        info "  Starting VM..."
        ${vm.runner}/bin/microvm-run &
        VM_BG_PID=$!

        if wait_for_process "$HOSTNAME" "${toString archTimeouts.start}"; then
          elapsed=$(elapsed_ms "$start_time")
          pid=$(vm_pid "$HOSTNAME")
          result_pass "VM process running (PID: $pid)" "$elapsed"
          record_pass
        else
          elapsed=$(elapsed_ms "$start_time")
          result_fail "VM process not found" "$elapsed"
          record_fail
          exit 1
        fi

        # Ensure cleanup on exit
        cleanup() {
          kill_vm "$HOSTNAME" 2>/dev/null || true
          wait "$VM_BG_PID" 2>/dev/null || true
        }
        trap cleanup EXIT

        # ─── Phase 2: Serial Console ──────────────────────────────────
        phase_header "2" "Serial Console (${archCfg.consoleDevice})" "${toString archTimeouts.serial}"
        start_time=$(time_ms)
        if wait_for_console "$SERIAL_PORT" "${toString archTimeouts.serial}"; then
          result_pass "Serial console available (port $SERIAL_PORT)" "$(elapsed_ms "$start_time")"
          record_pass
        else
          result_fail "Serial console not available" "$(elapsed_ms "$start_time")"
          record_fail
        fi

        # ─── Phase 2b: Virtio Console ─────────────────────────────────
        phase_header "2b" "Virtio Console (hvc0)" "${toString archTimeouts.virtio}"
        start_time=$(time_ms)
        if wait_for_console "$VIRTIO_PORT" "${toString archTimeouts.virtio}"; then
          result_pass "Virtio console available (port $VIRTIO_PORT)" "$(elapsed_ms "$start_time")"
          record_pass
        else
          result_fail "Virtio console not available" "$(elapsed_ms "$start_time")"
          record_fail
        fi

        # ─── Phase 3: SSH Reachable ───────────────────────────────────
        phase_header "3" "SSH Reachable" "${toString archTimeouts.ssh}"
        start_time=$(time_ms)

        info "  Waiting for SSH..."
        if ! wait_for_ssh "$SSH_HOST" "$SSH_PORT" "${toString archTimeouts.ssh}"; then
          result_fail "SSH not available" "$(elapsed_ms "$start_time")"
          record_fail
        else
          result_pass "SSH connected" "$(elapsed_ms "$start_time")"
          record_pass
        fi

        # ─── Phase 4: Load mac80211_hwsim ─────────────────────────────
        phase_header "4" "Load mac80211_hwsim (${toString radios} radios)" "${toString archTimeouts.moduleLoad}"
        ${tsfChecks.mkHwsimLoadCheck { inherit radios; }}

        # ─── Phase 5: Load tsf_ptp ────────────────────────────────────
        phase_header "5" "Load tsf_ptp" "${toString archTimeouts.moduleLoad}"
        ${tsfChecks.mkTsfPtpLoadCheck { inherit threshold syncMode; }}

        # ─── Phase 6: Verify PTP Clocks ───────────────────────────────
        phase_header "6" "Verify PTP Clocks" "${toString archTimeouts.ptpClocks}"
        ${tsfChecks.mkPtpClockCheck { expectedCount = radios; }}

        # ─── Phase 7: Verify sysfs Parameters ─────────────────────────
        phase_header "7" "Verify sysfs Parameters" "${toString archTimeouts.sysfsParams}"
        ${tsfChecks.mkSysfsParamCheck { inherit threshold; }}

        # ─── Phase 8: tsf-sync discover ───────────────────────────────
        phase_header "8" "tsf-sync discover" "${toString archTimeouts.discover}"
        ${tsfChecks.mkDiscoverCheck { expectedCount = radios; }}

        # ─── Phase 9: Adjtime Threshold Test ──────────────────────────
        phase_header "9" "Adjtime Threshold Test" "${toString archTimeouts.adjtimeThreshold}"
        ${tsfChecks.mkAdjtimeThresholdCheck { inherit threshold; }}

        # ─── Phase 10: Sync Mode Check ────────────────────────────────
        phase_header "10" "Sync Mode Check" "${toString archTimeouts.syncMode}"
        ${tsfChecks.mkSyncModeCheck { expectedMode = syncMode; }}

        # ─── Phase 11: tsf-sync status ────────────────────────────────
        phase_header "11" "tsf-sync status" "${toString archTimeouts.status}"
        ${tsfChecks.mkStatusCheck}

        ${lib.optionalString hasSelftest ''
        # ─── Phase 11a: Quick PTP Selftest ────────────────────────────
        phase_header "11a" "Quick PTP Selftest (wifi_ptp_test --quick)" "${toString archTimeouts.selftestQuick}"
        ${tsfChecks.mkSelftestQuickCheck}

        # ─── Phase 11b: Long PTP Selftest ─────────────────────────────
        phase_header "11b" "Long PTP Selftest (${toString selftestDuration}s)" "${toString archTimeouts.selftestLong}"
        ${tsfChecks.mkSelftestLongCheck { duration = selftestDuration; }}
        ''}

        # ─── Phase 12: Shutdown ───────────────────────────────────────
        phase_header "12" "Shutdown" "${toString archTimeouts.shutdown}"
        start_time=$(time_ms)

        info "  Sending shutdown command..."
        ssh_cmd "$SSH_HOST" "$SSH_PORT" "systemctl reboot" 2>/dev/null || true
        result_pass "Shutdown command sent" "$(elapsed_ms "$start_time")"
        record_pass

        # ─── Phase 13: Clean Exit ─────────────────────────────────────
        phase_header "13" "Clean Exit" "${toString archTimeouts.waitExit}"
        start_time=$(time_ms)

        if ! wait_for_exit "$HOSTNAME" 30; then
          info "  Guest still running after 30s, sending SIGTERM to QEMU..."
          qpid=$(vm_pid "$HOSTNAME")
          if [[ -n "$qpid" ]]; then
            kill "$qpid" 2>/dev/null || true
          fi
        fi

        if wait_for_exit "$HOSTNAME" 15; then
          result_pass "VM exited cleanly" "$(elapsed_ms "$start_time")"
          record_pass
        else
          result_fail "VM did not exit, forcing kill" "$(elapsed_ms "$start_time")"
          kill_vm "$HOSTNAME"
          record_fail
        fi

        trap - EXIT
        wait "$VM_BG_PID" 2>/dev/null || true

        # ─── Summary ──────────────────────────────────────────────────
        ${testSummary {
          label = "ALL PHASES PASSED";
          detail = "Arch: $ARCH | Variant: $VARIANT | Radios: ${toString radios}";
        }}
      '';
    };

  # Generate all test packages across all arch+variant combos
  allTests = lib.concatMapAttrs (
    name: vm:
    let
      parts = lib.splitString "-" name;
      arch = builtins.head parts;
      variantName = lib.concatStringsSep "-" (builtins.tail parts);
    in
    {
      "tsf-sync-lifecycle-test-${name}" = mkFullTest arch variantName;
    }
  ) microvmVariants;

  # Backwards-compat aliases: tsf-sync-lifecycle-test-<variant> → x86_64 variant
  x86Aliases = lib.concatMapAttrs (
    name: _:
    let
      prefixed = "x86_64-${name}";
    in
    lib.optionalAttrs (microvmVariants ? ${prefixed}) {
      "tsf-sync-lifecycle-test-${name}" = mkFullTest "x86_64" name;
    }
  ) constants.variants;

  # Test-all orchestrator
  testAll = pkgs.writeShellApplication {
    name = "tsf-sync-lifecycle-test-all";
    runtimeInputs = commonInputs;
    text = let
      testNames = builtins.attrNames allTests;
    in ''
      set +e
      TOTAL=0
      PASSED=0
      FAILED=0
      FAILED_NAMES=""

      ${lib.concatMapStringsSep "\n" (name: ''
        echo ""
        echo "========================================"
        echo "  Running: ${name}"
        echo "========================================"
        TOTAL=$((TOTAL + 1))
        if ${allTests.${name}}/bin/${name}; then
          PASSED=$((PASSED + 1))
        else
          FAILED=$((FAILED + 1))
          FAILED_NAMES="$FAILED_NAMES ${name}"
        fi
      '') testNames}

      echo ""
      echo "========================================"
      echo "  OVERALL: $PASSED/$TOTAL passed"
      if [[ $FAILED -gt 0 ]]; then
        echo "  FAILED:$FAILED_NAMES"
        exit 1
      fi
      echo "========================================"
    '';
  };

in
{
  packages = allTests // x86Aliases // {
    tsf-sync-lifecycle-test-all = testAll;
  };
}
