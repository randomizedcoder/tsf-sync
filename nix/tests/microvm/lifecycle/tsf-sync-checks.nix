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
}
