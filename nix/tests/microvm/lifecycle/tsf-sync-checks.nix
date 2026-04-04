# tsf-sync-specific verification functions for MicroVM lifecycle testing.
# Returns bash script fragments for hwsim, tsf_ptp, PTP clock, sysfs, and CLI checks.
#
{ lib }:
{
  # Phase 4: Load mac80211_hwsim with N radios, verify phy count
  mkHwsimLoadCheck =
    { radios }:
    ''
      hwsim_start=$(time_ms)
      info "  Loading mac80211_hwsim with ${toString radios} radios..."
      if ssh_cmd "$SSH_HOST" "$SSH_PORT" "modprobe mac80211_hwsim radios=${toString radios}"; then
        sleep 1
        phy_count=$(count_hwsim_phys "$SSH_HOST" "$SSH_PORT")
        if [[ "$phy_count" -ge ${toString radios} ]]; then
          result_pass "mac80211_hwsim loaded ($phy_count phys)" "$(elapsed_ms "$hwsim_start")"
          record_pass
        else
          result_fail "expected ${toString radios} phys, got $phy_count" "$(elapsed_ms "$hwsim_start")"
          record_fail
        fi
      else
        result_fail "modprobe mac80211_hwsim failed" "$(elapsed_ms "$hwsim_start")"
        record_fail
      fi
    '';

  # Phase 5: Load tsf_ptp with adjtime threshold and optional sync_mode
  mkTsfPtpLoadCheck =
    { threshold, syncMode ? 0 }:
    ''
      tsf_start=$(time_ms)
      info "  Loading tsf_ptp (threshold=${toString threshold}ns, sync_mode=${toString syncMode})..."
      if ssh_cmd "$SSH_HOST" "$SSH_PORT" "modprobe tsf_ptp adjtime_threshold_ns=${toString threshold} sync_mode=${toString syncMode}"; then
        sleep 1
        result_pass "tsf_ptp loaded" "$(elapsed_ms "$tsf_start")"
        record_pass
      else
        result_fail "modprobe tsf_ptp failed" "$(elapsed_ms "$tsf_start")"
        record_fail
      fi
    '';

  # Phase 6: Verify PTP clocks appear in sysfs
  mkPtpClockCheck =
    { expectedCount }:
    ''
      ptp_start=$(time_ms)
      ptp_count=$(count_ptp_clocks "$SSH_HOST" "$SSH_PORT")
      if [[ "$ptp_count" -ge ${toString expectedCount} ]]; then
        result_pass "PTP clocks: $ptp_count (expected >= ${toString expectedCount})" "$(elapsed_ms "$ptp_start")"
        record_pass
      else
        result_fail "PTP clocks: $ptp_count (expected >= ${toString expectedCount})" "$(elapsed_ms "$ptp_start")"
        record_fail
      fi
    '';

  # Phase 7: Read sysfs parameters
  mkSysfsParamCheck =
    { threshold }:
    ''
      sysfs_start=$(time_ms)
      actual_threshold=$(read_sysfs_param "$SSH_HOST" "$SSH_PORT" "adjtime_threshold_ns")
      skip_count=$(read_sysfs_param "$SSH_HOST" "$SSH_PORT" "adjtime_skip_count")
      apply_count=$(read_sysfs_param "$SSH_HOST" "$SSH_PORT" "adjtime_apply_count")

      if [[ "$actual_threshold" == "${toString threshold}" ]]; then
        result_pass "adjtime_threshold_ns = $actual_threshold" "$(elapsed_ms "$sysfs_start")"
        info "    adjtime_skip_count  = $skip_count"
        info "    adjtime_apply_count = $apply_count"
        record_pass
      else
        result_fail "adjtime_threshold_ns = $actual_threshold (expected ${toString threshold})" "$(elapsed_ms "$sysfs_start")"
        record_fail
      fi
    '';

  # Phase 8: tsf-sync discover
  mkDiscoverCheck =
    { expectedCount }:
    ''
      discover_start=$(time_ms)
      discover_output=$(ssh_cmd "$SSH_HOST" "$SSH_PORT" "tsf-sync discover 2>&1" || echo "")
      phy_entries=$(echo "$discover_output" | grep -c "phy" || echo "0")

      if [[ "$phy_entries" -ge ${toString expectedCount} ]]; then
        result_pass "tsf-sync discover found $phy_entries entries (expected >= ${toString expectedCount})" "$(elapsed_ms "$discover_start")"
        record_pass
      else
        result_fail "tsf-sync discover found $phy_entries entries (expected >= ${toString expectedCount})" "$(elapsed_ms "$discover_start")"
        info "    Output: $discover_output"
        record_fail
      fi
    '';

  # Phase 9: Adjtime threshold test — sub-threshold adj should be skipped,
  # above-threshold adj should be applied
  mkAdjtimeThresholdCheck =
    { threshold }:
    ''
      adj_start=$(time_ms)

      # Find first PTP device
      ptp_dev=$(ssh_cmd "$SSH_HOST" "$SSH_PORT" "ls /dev/ptp* 2>/dev/null | head -1" || echo "")
      if [[ -z "$ptp_dev" ]]; then
        result_fail "No /dev/ptp* device found" "$(elapsed_ms "$adj_start")"
        record_fail
      else
        # Small adj below threshold (1000 ns) — should be skipped
        ssh_cmd "$SSH_HOST" "$SSH_PORT" "phc_ctl $ptp_dev -- adj 0.000001" 2>/dev/null || true
        sleep 0.5
        skip_after=$(read_sysfs_param "$SSH_HOST" "$SSH_PORT" "adjtime_skip_count")
        if [[ "$skip_after" -ge 1 ]]; then
          result_pass "Sub-threshold adj: skip_count = $skip_after" "$(elapsed_ms "$adj_start")"
          record_pass
        else
          result_fail "Sub-threshold adj: skip_count = $skip_after (expected >= 1)" "$(elapsed_ms "$adj_start")"
          record_fail
        fi

        # Large adj above threshold (10000 ns) — should be applied
        apply_start=$(time_ms)
        ssh_cmd "$SSH_HOST" "$SSH_PORT" "phc_ctl $ptp_dev -- adj 0.00001" 2>/dev/null || true
        sleep 0.5
        apply_after=$(read_sysfs_param "$SSH_HOST" "$SSH_PORT" "adjtime_apply_count")
        if [[ "$apply_after" -ge 1 ]]; then
          result_pass "Above-threshold adj: apply_count = $apply_after" "$(elapsed_ms "$apply_start")"
          record_pass
        else
          result_fail "Above-threshold adj: apply_count = $apply_after (expected >= 1)" "$(elapsed_ms "$apply_start")"
          record_fail
        fi
      fi
    '';

  # Phase 10: Sync mode check
  mkSyncModeCheck =
    { expectedMode ? 0 }:
    ''
      sync_start=$(time_ms)
      sync_mode=$(read_sysfs_param "$SSH_HOST" "$SSH_PORT" "sync_mode")
      if [[ "$sync_mode" == "${toString expectedMode}" ]]; then
        result_pass "sync_mode = $sync_mode" "$(elapsed_ms "$sync_start")"
        record_pass
      else
        result_fail "sync_mode = $sync_mode (expected ${toString expectedMode})" "$(elapsed_ms "$sync_start")"
        record_fail
      fi
    '';

  # Phase 11: tsf-sync status
  mkStatusCheck = ''
    status_start=$(time_ms)
    if ssh_cmd "$SSH_HOST" "$SSH_PORT" "tsf-sync status" >/dev/null 2>&1; then
      result_pass "tsf-sync status" "$(elapsed_ms "$status_start")"
      record_pass
    else
      result_fail "tsf-sync status" "$(elapsed_ms "$status_start")"
      record_fail
    fi
  '';

  # Phase 11a: Quick PTP selftest (--quick skips long-running stability test)
  #
  # In the hwsim environment, read-only tests (monotonicity, rapid_fire_stress)
  # always pass. Write-dependent tests (set_get_roundtrip, adjtime_accuracy)
  # may fail because hwsim's set_tsf doesn't take effect through the tsf_ptp
  # module (epoch-based TSF, no real hardware write path).
  #
  # Pass criteria: read-only tests must pass. Write failures are reported as
  # warnings, not hard failures — they require real hardware to validate.
  mkSelftestQuickCheck = ''
    selftest_quick_start=$(time_ms)

    # Bring up a wireless interface for best-effort write support
    ssh_cmd "$SSH_HOST" "$SSH_PORT" "ip link set wlan0 up 2>/dev/null" || true
    sleep 0.5

    # Find first PTP device
    ptp_dev=$(ssh_cmd "$SSH_HOST" "$SSH_PORT" "ls /dev/ptp* 2>/dev/null | head -1" || echo "")
    if [[ -z "$ptp_dev" ]]; then
      result_fail "No /dev/ptp* device for selftest" "$(elapsed_ms "$selftest_quick_start")"
      record_fail
    else
      info "  Running wifi_ptp_test --quick on $ptp_dev..."
      selftest_output=$(ssh_cmd "$SSH_HOST" "$SSH_PORT" "wifi_ptp_test $ptp_dev --quick --verbose 2>&1" || true)

      # Check if the binary ran at all (TAP header present = test executed)
      if ! echo "$selftest_output" | grep -q "^TAP version"; then
        result_fail "wifi_ptp_test --quick: failed to execute" "$(elapsed_ms "$selftest_quick_start")"
        record_fail
      else
        # Parse TAP output: read-only tests are the hard pass criteria
        ok_count=$(echo "$selftest_output" | grep -c '^ok ' || echo "0")
        not_ok_count=$(echo "$selftest_output" | grep -c '^not ok' || echo "0")
        total=$((ok_count + not_ok_count))

        # Check that read-only tests passed (monotonicity, rapid_fire_stress)
        mono_ok=$(echo "$selftest_output" | grep -c '^ok - monotonicity' || echo "0")
        stress_ok=$(echo "$selftest_output" | grep -c '^ok - rapid_fire_stress' || echo "0")

        # Write-dependent failures: set_get_roundtrip, adjtime_accuracy
        write_fails=$(echo "$selftest_output" | grep -c '^not ok.*\(set_get\|adjtime\)' || echo "0")

        if [[ "$mono_ok" -ge 1 && "$stress_ok" -ge 1 ]]; then
          if [[ "$not_ok_count" -eq 0 ]]; then
            result_pass "wifi_ptp_test --quick: $ok_count/$total passed" "$(elapsed_ms "$selftest_quick_start")"
          elif [[ "$write_fails" -eq "$not_ok_count" ]]; then
            # All failures are write-dependent — expected in hwsim
            result_pass "wifi_ptp_test --quick: $ok_count/$total passed ($write_fails write-tests skipped in hwsim)" "$(elapsed_ms "$selftest_quick_start")"
            warn "    Write-dependent tests need real hardware (set_get_roundtrip, adjtime_accuracy)"
          else
            # Unexpected failure in a read-only test
            result_fail "wifi_ptp_test --quick: $not_ok_count test(s) failed" "$(elapsed_ms "$selftest_quick_start")"
            echo "$selftest_output" | grep -E '^(ok|not ok|#)' | while IFS= read -r line; do
              info "      $line"
            done
            record_fail
          fi
          record_pass
        else
          result_fail "wifi_ptp_test --quick: read-only tests failed (mono=$mono_ok stress=$stress_ok)" "$(elapsed_ms "$selftest_quick_start")"
          echo "$selftest_output" | grep -E '^(ok|not ok|#)' | while IFS= read -r line; do
            info "      $line"
          done
          record_fail
        fi
      fi
    fi
  '';

  # Phase 11b: Long PTP selftest (includes stability test over configurable duration)
  #
  # Same hwsim expectations as quick test, plus the long_running_stability
  # test which is read-only and must pass.
  mkSelftestLongCheck =
    { duration ? 60 }:
    ''
      selftest_long_start=$(time_ms)

      ptp_dev=$(ssh_cmd "$SSH_HOST" "$SSH_PORT" "ls /dev/ptp* 2>/dev/null | head -1" || echo "")
      if [[ -z "$ptp_dev" ]]; then
        result_fail "No /dev/ptp* device for long selftest" "$(elapsed_ms "$selftest_long_start")"
        record_fail
      else
        info "  Running wifi_ptp_test --duration ${toString duration} on $ptp_dev..."
        selftest_output=$(ssh_cmd "$SSH_HOST" "$SSH_PORT" "wifi_ptp_test $ptp_dev --duration ${toString duration} --verbose 2>&1" || true)

        if ! echo "$selftest_output" | grep -q "^TAP version"; then
          result_fail "wifi_ptp_test long: failed to execute" "$(elapsed_ms "$selftest_long_start")"
          record_fail
        else
          ok_count=$(echo "$selftest_output" | grep -c '^ok ' || echo "0")
          not_ok_count=$(echo "$selftest_output" | grep -c '^not ok' || echo "0")
          total=$((ok_count + not_ok_count))

          # Read-only tests: monotonicity, rapid_fire_stress, long_running_stability
          mono_ok=$(echo "$selftest_output" | grep -c '^ok - monotonicity' || echo "0")
          stress_ok=$(echo "$selftest_output" | grep -c '^ok - rapid_fire_stress' || echo "0")
          longrun_ok=$(echo "$selftest_output" | grep -c '^ok - long_running_stability' || echo "0")

          write_fails=$(echo "$selftest_output" | grep -c '^not ok.*\(set_get\|adjtime\)' || echo "0")

          if [[ "$mono_ok" -ge 1 && "$stress_ok" -ge 1 && "$longrun_ok" -ge 1 ]]; then
            if [[ "$not_ok_count" -eq 0 ]]; then
              result_pass "wifi_ptp_test long (${toString duration}s): $ok_count/$total passed" "$(elapsed_ms "$selftest_long_start")"
            elif [[ "$write_fails" -eq "$not_ok_count" ]]; then
              result_pass "wifi_ptp_test long (${toString duration}s): $ok_count/$total passed ($write_fails write-tests skipped in hwsim)" "$(elapsed_ms "$selftest_long_start")"
              warn "    Write-dependent tests need real hardware (set_get_roundtrip, adjtime_accuracy)"
            else
              result_fail "wifi_ptp_test long: $not_ok_count test(s) failed" "$(elapsed_ms "$selftest_long_start")"
              echo "$selftest_output" | grep -E '^(ok|not ok|#)' | while IFS= read -r line; do
                info "      $line"
              done
              record_fail
            fi
            record_pass
          else
            result_fail "wifi_ptp_test long: read-only tests failed (mono=$mono_ok stress=$stress_ok longrun=$longrun_ok)" "$(elapsed_ms "$selftest_long_start")"
            echo "$selftest_output" | grep -E '^(ok|not ok|#)' | while IFS= read -r line; do
              info "      $line"
            done
            record_fail
          fi
        fi
      fi
    '';
}
