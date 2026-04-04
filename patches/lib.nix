# Shared infrastructure for upstream WiFi PTP patches.
#
# Provides functions to:
#   - Verify patches apply cleanly to kernel source (pinned, stable, latest)
#   - Build a full kernel with patches applied
#   - Generate microVM test configurations with patched kernels
#
{ pkgs, lib }:
let
  pinnedKernelSource = import ./kernel-source.nix {
    inherit (pkgs) fetchFromGitHub;
  };

  # Multiple kernel sources for cross-version patch verification.
  #   pinned — development target (v6.12), always tested
  #   stable — pkgs.linuxPackages (latest stable from nixpkgs)
  #   latest — pkgs.linuxPackages_latest (bleeding edge from nixpkgs)
  kernelSources = {
    pinned = {
      label = "v6.12";
      src = pinnedKernelSource;
    };
    stable = {
      label = "stable-${pkgs.linuxPackages.kernel.version}";
      src = pkgs.linuxPackages.kernel.src;
    };
    latest = {
      label = "latest-${pkgs.linuxPackages_latest.kernel.version}";
      src = pkgs.linuxPackages_latest.kernel.src;
    };
  };

  driverPatches = [
    { name = "ath9k-ptp";  patch = ./ath9k/0001-wifi-ath9k-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "mt76-ptp";   patch = ./mt76/0001-wifi-mt76-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "rtw88-ptp";  patch = ./rtw88/0001-wifi-rtw88-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "rtw89-ptp";  patch = ./rtw89/0001-wifi-rtw89-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "ath10k-ptp"; patch = ./ath10k/0001-wifi-ath10k-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "ath11k-ptp"; patch = ./ath11k/0001-wifi-ath11k-add-ptp-hardware-clock-for-tsf.patch; }
  ];
in
{
  inherit pinnedKernelSource kernelSources driverPatches;

  # Backward compatibility alias.
  kernelSource = pinnedKernelSource;

  # ── Fast check: verify a single patch applies cleanly (no build) ─────
  #
  # Handles both unpacked directories (fetchFromGitHub) and tarballs
  # (fetchurl from nixpkgs kernel packages).
  mkPatchCheck = { name, patch, kernelSrc ? pinnedKernelSource, srcLabel ? "v6.12" }:
    pkgs.runCommand "patch-check-${name}-${srcLabel}" {
      nativeBuildInputs = with pkgs; [ gnupatch gnutar xz ];
    } ''
      if [ -d "${kernelSrc}" ]; then
        cp -r "${kernelSrc}" src
      else
        mkdir src && tar xf "${kernelSrc}" -C src --strip-components=1
      fi
      chmod -R u+w src
      cd src
      echo "Checking: ${name} against kernel ${srcLabel}"
      patch -p1 --dry-run < ${patch}
      echo "PASS: ${name} applies cleanly against ${srcLabel}"
      mkdir -p $out
      echo "${name}" > $out/name
    '';

  # ── Full build: kernel with one patch applied ────────────────────────
  #
  # Uses nixpkgs' kernelPatches mechanism. Builds the entire kernel
  # (cached — only rebuilds affected modules). The result is a full
  # kernel package with the patched driver.
  mkPatchedKernel = { name, patch, kernelPackages ? pkgs.linuxPackages }:
    kernelPackages.kernel.override {
      kernelPatches = [{
        inherit name patch;
      }];
    };

  # ── Full build: kernel with ALL patches applied ──────────────────────
  #
  # For the microVM test: builds a single kernel with every driver patch.
  mkAllPatchedKernel = { kernelPackages ? pkgs.linuxPackages }:
    kernelPackages.kernel.override {
      kernelPatches = map (p: {
        inherit (p) name patch;
      }) driverPatches;
    };

  # ── Combined check: all patches apply to the same tree ──────────────
  #
  # Applies all patches sequentially to verify they don't conflict.
  mkAllPatchesCheck = { kernelSrc ? pinnedKernelSource, srcLabel ? "v6.12" }:
    pkgs.runCommand "patch-check-all-${srcLabel}" {
      nativeBuildInputs = with pkgs; [ gnupatch gnutar xz ];
    } ''
      if [ -d "${kernelSrc}" ]; then
        cp -r "${kernelSrc}" src
      else
        mkdir src && tar xf "${kernelSrc}" -C src --strip-components=1
      fi
      chmod -R u+w src
      cd src
      ${lib.concatMapStringsSep "\n" (p: ''
        echo "Applying: ${p.name}"
        patch -p1 < ${p.patch}
      '') driverPatches}
      echo "PASS: all ${toString (builtins.length driverPatches)} patches apply against ${srcLabel}"
      mkdir -p $out
      echo "all" > $out/name
    '';
}
