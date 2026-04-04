# Automated test targets for upstream PTP patches.
#
# Provides writeShellApplication scripts for:
#   - Patch verification (apply-check against pinned kernel source)
#   - Per-driver patch inspection (show diffstat, affected files)
#   - Full kernel build with patches applied
#   - Patch format/style checks (kernel checkpatch.pl conventions)
#
# All scripts follow the project's writeShellApplication convention
# (see nix/scripts.nix for examples).
#
# Usage:
#   nix run .#patch-verify              # Check all patches apply
#   nix run .#patch-verify -- ath9k     # Check one driver
#   nix run .#patch-inspect             # Show diffstat for all patches
#   nix run .#patch-inspect -- mt76     # Show one driver's changes
#   nix run .#patch-test-format         # Check patch formatting
#   nix build .#patch-kernel-all        # Full kernel build (slow, cached)
#
{ pkgs, lib, mkMicrovm ? null, microvmVariants ? {} }:
let
  patchLib = import ../lib.nix { inherit pkgs lib; };

  driverNames = map (d: d.name) patchLib.driverPatches;

  # Helper: find a driver patch by short name (e.g., "ath9k" matches "ath9k-ptp")
  findPatch = name:
    let matches = builtins.filter (d: lib.hasPrefix name d.name) patchLib.driverPatches;
    in if matches == [] then null else builtins.head matches;

  # ── patch-verify: check patches apply cleanly ──────────────────────
  #
  # Fast (no kernel build). Copies pinned kernel source, applies each
  # patch with --dry-run, then applies all sequentially to check for
  # inter-patch conflicts.
  #
  #   nix run .#patch-verify              # all drivers
  #   nix run .#patch-verify -- ath9k     # single driver
  #   nix run .#patch-verify -- --verbose # show patch output
  #
  patch-verify = pkgs.writeShellApplication {
    name = "tsf-sync-patch-verify";
    runtimeInputs = with pkgs; [ gnupatch coreutils diffutils ];
    text = ''
      FILTER="''${1:-}"
      VERBOSE="''${2:-}"

      echo "=== Upstream PTP Patch Verification ==="
      echo ""
      echo "Kernel source: torvalds/linux (pinned)"
      echo "Patches: ${toString (builtins.length patchLib.driverPatches)} drivers"
      echo ""

      src=$(mktemp -d)
      trap 'rm -rf $src' EXIT
      cp -r ${patchLib.kernelSource} "$src/linux"
      chmod -R u+w "$src/linux"
      cd "$src/linux"

      passed=0
      failed=0
      skipped=0

      ${lib.concatMapStringsSep "\n" (drv: ''
        driver_short="${lib.removeSuffix "-ptp" drv.name}"
        if [ -n "$FILTER" ] && [ "$FILTER" != "--verbose" ] && [ "$driver_short" != "$FILTER" ]; then
          skipped=$((skipped + 1))
        else
          printf "  %-14s " "${drv.name}"
          if [ "$VERBOSE" = "--verbose" ] || [ "$FILTER" = "--verbose" ]; then
            if patch -p1 --dry-run < ${drv.patch}; then
              echo "  -> PASS"
              passed=$((passed + 1))
            else
              echo "  -> FAIL"
              failed=$((failed + 1))
            fi
          else
            if patch -p1 --dry-run < ${drv.patch} > /dev/null 2>&1; then
              echo "PASS"
              passed=$((passed + 1))
            else
              echo "FAIL"
              patch -p1 --dry-run < ${drv.patch} 2>&1 | head -20
              failed=$((failed + 1))
            fi
          fi
        fi
      '') patchLib.driverPatches}

      echo ""
      total=$((passed + failed))
      echo "Results: $passed/$total passed, $failed failed, $skipped skipped"

      if [ "$failed" -gt 0 ]; then
        echo ""
        echo "FAIL: some patches did not apply cleanly"
        exit 1
      fi

      if [ -z "$FILTER" ] || [ "$FILTER" = "--verbose" ]; then
        echo ""
        echo "==> Applying all patches sequentially (conflict check)..."

        ${lib.concatMapStringsSep "\n" (drv: ''
          echo "  Applying: ${drv.name}"
          patch -p1 < ${drv.patch}
        '') patchLib.driverPatches}

        echo ""
        echo "PASS: all $total patches apply cleanly, no conflicts"
      fi
    '';
  };

  # ── patch-inspect: show what each patch changes ────────────────────
  #
  # Displays diffstat, affected files, and new file list for each
  # driver patch. Useful for review before submission.
  #
  #   nix run .#patch-inspect              # all drivers
  #   nix run .#patch-inspect -- ath9k     # single driver
  #   nix run .#patch-inspect -- --full    # show full diff
  #
  patch-inspect = pkgs.writeShellApplication {
    name = "tsf-sync-patch-inspect";
    runtimeInputs = with pkgs; [ diffstat coreutils gnugrep gawk ];
    text = ''
      FILTER="''${1:-}"

      echo "=== Upstream PTP Patch Inspection ==="
      echo ""

      ${lib.concatMapStringsSep "\n" (drv: ''
        driver_short="${lib.removeSuffix "-ptp" drv.name}"
        if [ -n "$FILTER" ] && [ "$FILTER" != "--full" ] && [ "$driver_short" != "$FILTER" ]; then
          :
        else
          echo "── ${drv.name} ──────────────────────────────────"
          echo ""

          # Extract commit message (everything between Subject: and ---)
          subject=$(grep '^Subject:' ${drv.patch} | sed 's/^Subject: \[PATCH\] //')
          echo "  Subject: $subject"
          echo ""

          # Diffstat
          echo "  Files changed:"
          diffstat -p1 < ${drv.patch} | sed 's/^/    /'
          echo ""

          # New files
          new_files=$(grep -c '^new file mode' ${drv.patch} || true)
          if [ "$new_files" -gt 0 ]; then
            echo "  New files ($new_files):"
            grep -B1 '^new file mode' ${drv.patch} | grep '^diff --git' | \
              awk '{print "    " $NF}' | sed 's|b/||'
            echo ""
          fi

          # Lines added/removed
          added=$(grep -c '^+[^+]' ${drv.patch} || true)
          removed=$(grep -c '^-[^-]' ${drv.patch} || true)
          echo "  Lines: +$added -$removed"
          echo ""

          if [ "$FILTER" = "--full" ]; then
            echo "  Full diff:"
            cat ${drv.patch}
            echo ""
          fi
        fi
      '') patchLib.driverPatches}

      echo "── Summary ──────────────────────────────────────"
      echo ""
      echo "  Drivers: ${toString (builtins.length patchLib.driverPatches)}"
      echo "  Register-based (low latency):  ath9k, rtw88, rtw89"
      echo "  Abstracted (per-chipset ops):  mt76"
      echo "  WMI firmware (higher latency): ath10k, ath11k"
    '';
  };

  # ── patch-test-format: check patch formatting ──────────────────────
  #
  # Validates that patches follow kernel submission conventions:
  #   - Has Signed-off-by line
  #   - Subject line follows wifi: <driver>: convention
  #   - No trailing whitespace in patch content
  #   - New files have SPDX license header
  #   - Includes header guard for .h files
  #
  #   nix run .#patch-test-format
  #
  patch-test-format = pkgs.writeShellApplication {
    name = "tsf-sync-patch-test-format";
    runtimeInputs = with pkgs; [ coreutils gnugrep gawk ];
    text = ''
      echo "=== Patch Format Checks ==="
      echo ""

      errors=0

      check() {
        local patch="$1"
        local name="$2"
        local issues=0

        printf "  %-14s " "$name"

        # 1. Signed-off-by present
        if ! grep -q '^Signed-off-by:' "$patch"; then
          echo ""
          echo "    WARN: missing Signed-off-by line"
          issues=$((issues + 1))
        fi

        # 2. Subject follows wifi: <driver>: convention
        if ! grep -q '^Subject:.*wifi:' "$patch"; then
          echo ""
          echo "    WARN: Subject doesn't follow 'wifi: <driver>:' convention"
          issues=$((issues + 1))
        fi

        # 3. New .c files have SPDX header
        if ! grep -q '^+// SPDX-License-Identifier:' "$patch" && \
           ! grep -q '^+/\* SPDX-License-Identifier:' "$patch"; then
          if grep -q 'new file.*\.c' "$patch"; then
            echo ""
            echo "    WARN: new .c files should have SPDX license header"
            issues=$((issues + 1))
          fi
        fi

        # 4. New .h files have include guard
        if grep -q 'new file.*\.h' "$patch"; then
          if ! grep -q '^+#ifndef' "$patch"; then
            echo ""
            echo "    WARN: .h files should have #ifndef include guard"
            issues=$((issues + 1))
          fi
        fi

        # 5. No trailing whitespace in added lines
        trailing=$(grep -c '^+.*[[:space:]]$' "$patch" || true)
        if [ "$trailing" -gt 0 ]; then
          echo ""
          echo "    WARN: $trailing lines with trailing whitespace"
          issues=$((issues + 1))
        fi

        if [ "$issues" -eq 0 ]; then
          echo "PASS"
        else
          errors=$((errors + issues))
        fi
      }

      ${lib.concatMapStringsSep "\n" (drv: ''
        check ${drv.patch} "${drv.name}"
      '') patchLib.driverPatches}

      echo ""
      if [ "$errors" -eq 0 ]; then
        echo "All format checks passed."
      else
        echo "$errors format issues found (warnings only, patches may still be valid)."
      fi
    '';
  };

  # ── patch-test-build: verify patches compile in kernel build ───────
  #
  # Triggers a full kernel build with all patches applied. This is slow
  # (~20-60 min first time) but fully cached by Nix after the first run.
  # Verifies no compile errors from our additions.
  #
  #   nix run .#patch-test-build
  #
  patchedKernel = pkgs.linuxPackages.kernel.override {
    kernelPatches = map (p: {
      inherit (p) name patch;
    }) patchLib.driverPatches;
  };

  patch-test-build = pkgs.writeShellApplication {
    name = "tsf-sync-patch-test-build";
    runtimeInputs = with pkgs; [ coreutils nix ];
    text = ''
      echo "=== Patch Build Verification ==="
      echo ""
      echo "Building kernel with all ${toString (builtins.length patchLib.driverPatches)} PTP patches applied..."
      echo "This may take a while on first run (cached afterward)."
      echo ""

      # Build the patched kernel — Nix handles caching.
      nix build ${
        # We can't self-reference the flake output here, so we build
        # the kernel derivation directly.
        "\"${patchedKernel}\""
      } --no-link --print-build-logs 2>&1 | tail -20

      echo ""
      echo "PASS: kernel with all patches compiles successfully"
      echo ""

      # Show which modules were built
      echo "Patched drivers:"
      ${lib.concatMapStringsSep "\n" (drv: ''
        echo "  - ${drv.name}"
      '') patchLib.driverPatches}
    '';
  };

  # ── patch-test-all: run all automated checks ───────────────────────
  #
  # Runs the full test suite for patches:
  #   1. Format checks (fast)
  #   2. Apply verification (fast)
  #   3. Conflict detection (fast)
  #
  # Does NOT include kernel build (use patch-test-build for that).
  #
  #   nix run .#patch-test-all
  #
  patch-test-all = pkgs.writeShellApplication {
    name = "tsf-sync-patch-test-all";
    runtimeInputs = with pkgs; [ gnupatch diffstat coreutils gnugrep gawk gnutar xz ];
    text = ''
      echo "╔══════════════════════════════════════════════════╗"
      echo "║  Upstream PTP Patch — Full Test Suite            ║"
      echo "╚══════════════════════════════════════════════════╝"
      echo ""

      ERRORS=0

      # ── Phase 1: Format checks ──────────────────────────────────
      echo "┌─ Phase 1: Format checks ─────────────────────────┐"
      echo ""

      format_issues=0
      ${lib.concatMapStringsSep "\n" (drv: ''
        printf "  %-14s " "${drv.name}"
        issues=0

        if ! grep -q '^Signed-off-by:' ${drv.patch}; then
          issues=$((issues + 1))
        fi
        if ! grep -q '^Subject:.*wifi:' ${drv.patch}; then
          issues=$((issues + 1))
        fi
        trailing=$(grep -c '^+.*[[:space:]]$' ${drv.patch} || true)
        if [ "$trailing" -gt 0 ]; then
          issues=$((issues + issues))
        fi

        if [ "$issues" -eq 0 ]; then
          echo "PASS"
        else
          echo "WARN ($issues issues)"
          format_issues=$((format_issues + issues))
        fi
      '') patchLib.driverPatches}

      echo ""
      if [ "$format_issues" -eq 0 ]; then
        echo "  Format: all checks passed"
      else
        echo "  Format: $format_issues warnings"
      fi
      echo ""

      # ── Phase 2: Patch apply (dry-run) ──────────────────────────
      echo "┌─ Phase 2: Apply verification ─────────────────────┐"
      echo ""

      src=$(mktemp -d)
      trap 'rm -rf $src' EXIT
      cp -r ${patchLib.kernelSource} "$src/linux"
      chmod -R u+w "$src/linux"
      cd "$src/linux"

      apply_pass=0
      apply_fail=0
      ${lib.concatMapStringsSep "\n" (drv: ''
        printf "  %-14s " "${drv.name}"
        if patch -p1 --dry-run < ${drv.patch} > /dev/null 2>&1; then
          echo "PASS"
          apply_pass=$((apply_pass + 1))
        else
          echo "FAIL"
          apply_fail=$((apply_fail + 1))
          ERRORS=$((ERRORS + 1))
        fi
      '') patchLib.driverPatches}

      echo ""
      total=$((apply_pass + apply_fail))
      echo "  Apply: $apply_pass/$total passed"
      echo ""

      # ── Phase 2b: Multi-kernel verification ─────────────────────
      echo "┌─ Phase 2b: Multi-kernel verification ──────────────┐"
      echo ""
      echo "  Testing patches against additional kernel versions."
      echo "  Failures here indicate patches may need updating."
      echo ""

      prepare_kernel_src() {
        local dest="$1"
        local ksrc="$2"
        rm -rf "$dest"
        if [ -d "$ksrc" ]; then
          cp -r "$ksrc" "$dest"
        else
          mkdir -p "$dest"
          tar xf "$ksrc" -C "$dest" --strip-components=1
        fi
        chmod -R u+w "$dest"
      }

      echo "  Kernel: ${patchLib.kernelSources.stable.label}"
      prepare_kernel_src "$src/kern" "${patchLib.kernelSources.stable.src}"
      cd "$src/kern"

      stable_pass=0
      stable_fail=0
      ${lib.concatMapStringsSep "\n" (drv: ''
        printf "    %-14s " "${drv.name}"
        if patch -p1 --dry-run < ${drv.patch} > /dev/null 2>&1; then
          echo "PASS"
          stable_pass=$((stable_pass + 1))
        else
          echo "FAIL"
          stable_fail=$((stable_fail + 1))
        fi
      '') patchLib.driverPatches}
      echo ""

      echo "  Kernel: ${patchLib.kernelSources.latest.label}"
      prepare_kernel_src "$src/kern" "${patchLib.kernelSources.latest.src}"
      cd "$src/kern"

      latest_pass=0
      latest_fail=0
      ${lib.concatMapStringsSep "\n" (drv: ''
        printf "    %-14s " "${drv.name}"
        if patch -p1 --dry-run < ${drv.patch} > /dev/null 2>&1; then
          echo "PASS"
          latest_pass=$((latest_pass + 1))
        else
          echo "FAIL"
          latest_fail=$((latest_fail + 1))
        fi
      '') patchLib.driverPatches}
      echo ""

      echo "  Stable: $stable_pass/${toString (builtins.length patchLib.driverPatches)} passed"
      echo "  Latest: $latest_pass/${toString (builtins.length patchLib.driverPatches)} passed"
      if [ "$stable_fail" -gt 0 ] || [ "$latest_fail" -gt 0 ]; then
        echo "  WARNING: some patches may need updating for newer kernels"
      fi
      echo ""

      # ── Phase 3: Sequential apply (conflict check) ──────────────
      echo "┌─ Phase 3: Conflict detection ─────────────────────┐"
      echo ""

      # Re-copy clean source for sequential apply
      rm -rf "$src/linux"
      cp -r ${patchLib.kernelSource} "$src/linux"
      chmod -R u+w "$src/linux"
      cd "$src/linux"

      conflict=0
      ${lib.concatMapStringsSep "\n" (drv: ''
        printf "  %-14s " "${drv.name}"
        if patch -p1 < ${drv.patch} > /dev/null 2>&1; then
          echo "OK"
        else
          echo "CONFLICT"
          conflict=$((conflict + 1))
          ERRORS=$((ERRORS + 1))
        fi
      '') patchLib.driverPatches}

      echo ""
      if [ "$conflict" -eq 0 ]; then
        echo "  Conflicts: none"
      else
        echo "  Conflicts: $conflict patches conflicted"
      fi
      echo ""

      # ── Phase 4: Patch statistics ───────────────────────────────
      echo "┌─ Phase 4: Patch statistics ───────────────────────┐"
      echo ""

      total_added=0
      total_removed=0
      ${lib.concatMapStringsSep "\n" (drv: ''
        added=$(grep -c '^+[^+]' ${drv.patch} || true)
        removed=$(grep -c '^-[^-]' ${drv.patch} || true)
        new_files=$(grep -c '^new file mode' ${drv.patch} || true)
        printf "  %-14s +%-4d -%-4d (%d new files)\n" "${drv.name}" "$added" "$removed" "$new_files"
        total_added=$((total_added + added))
        total_removed=$((total_removed + removed))
      '') patchLib.driverPatches}

      echo ""
      echo "  Total: +$total_added -$total_removed across ${toString (builtins.length patchLib.driverPatches)} drivers"
      echo ""

      # ── Summary ─────────────────────────────────────────────────
      echo "╔══════════════════════════════════════════════════╗"
      if [ "$ERRORS" -eq 0 ]; then
        echo "║  PASS: all automated checks passed               ║"
      else
        echo "║  FAIL: $ERRORS error(s) found                         ║"
      fi
      echo "╚══════════════════════════════════════════════════╝"
      echo ""

      if [ "$ERRORS" -eq 0 ]; then
        echo "Next steps:"
        echo "  nix run .#patch-test-build   # Full kernel compile check"
        echo "  nix run .#patch-inspect      # Review individual patches"
      fi

      exit "$ERRORS"
    '';
  };

in
{
  packages = {
    inherit patch-verify patch-inspect patch-test-format patch-test-build patch-test-all;
    patch-kernel-all = patchedKernel;
  };
}
