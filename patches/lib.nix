# Shared infrastructure for upstream WiFi PTP patches.
#
# Provides functions to:
#   - Verify patches apply cleanly to pinned kernel source
#   - Build a full kernel with patches applied
#   - Generate microVM test configurations with patched kernels
#
{ pkgs, lib }:
let
  kernelSource = import ./kernel-source.nix {
    inherit (pkgs) fetchFromGitHub;
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
  inherit kernelSource driverPatches;

  # ── Fast check: verify a single patch applies cleanly (no build) ─────
  #
  # Copies the pinned kernel source, runs `patch -p1 --dry-run`, and
  # succeeds only if the patch applies without rejects.
  mkPatchCheck = { name, patch }:
    pkgs.runCommand "patch-check-${name}" {
      nativeBuildInputs = [ pkgs.gnupatch ];
    } ''
      cp -r ${kernelSource} src
      chmod -R u+w src
      cd src
      echo "Checking patch: ${name}"
      patch -p1 --dry-run < ${patch}
      echo "PASS: ${name} applies cleanly"
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
  mkAllPatchesCheck =
    pkgs.runCommand "patch-check-all" {
      nativeBuildInputs = [ pkgs.gnupatch ];
    } ''
      cp -r ${kernelSource} src
      chmod -R u+w src
      cd src
      ${lib.concatMapStringsSep "\n" (p: ''
        echo "Applying: ${p.name}"
        patch -p1 < ${p.patch}
      '') driverPatches}
      echo "PASS: all ${toString (builtins.length driverPatches)} patches apply cleanly"
      mkdir -p $out
      echo "all" > $out/name
    '';
}
