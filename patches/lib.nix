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
  #   net-next — netdev/net-next development tree (pre-merge networking patches)
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
    # net-next — tracks the netdev/net-next development tree.
    # WiFi driver patches land here before mainline merge windows.
    #
    # To update:
    #   1. Get the latest commit:
    #      git ls-remote https://git.kernel.org/pub/scm/linux/kernel/git/netdev/net-next.git HEAD
    #   2. Update `rev` below
    #   3. Set `hash = ""` — Nix will error with the correct hash
    #   4. Paste the correct hash
    net-next = let
      rev = "3741f8fa004bf598cd5032b0ff240984332d6f05";
    in {
      label = "net-next-${builtins.substring 0 12 rev}";
      src = pkgs.fetchzip {
        url = "https://git.kernel.org/pub/scm/linux/kernel/git/netdev/net-next.git/snapshot/${rev}.tar.gz";
        hash = "sha256-642CQpg8bIsCdioUEsljb/kguHuc8irfD5N+Ed9meEg=";
      };
    };
  };

  # Patches targeting pinned v6.12 (development baseline).
  driverPatches = [
    { name = "ath9k-ptp";  patch = ./ath9k/0001-wifi-ath9k-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "mt76-ptp";   patch = ./mt76/0001-wifi-mt76-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "rtw88-ptp";  patch = ./rtw88/0001-wifi-rtw88-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "rtw89-ptp";  patch = ./rtw89/0001-wifi-rtw89-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "ath10k-ptp"; patch = ./ath10k/0001-wifi-ath10k-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "ath11k-ptp"; patch = ./ath11k/0001-wifi-ath11k-add-ptp-hardware-clock-for-tsf.patch; }
  ];

  # Patches rebased for net-next (submission target).
  # Start as copies of v6.12 patches; rebase each against the net-next source.
  driverPatchesNetNext = [
    { name = "ath9k-ptp";  patch = ./net-next/ath9k/0001-wifi-ath9k-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "mt76-ptp";   patch = ./net-next/mt76/0001-wifi-mt76-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "rtw88-ptp";  patch = ./net-next/rtw88/0001-wifi-rtw88-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "rtw89-ptp";  patch = ./net-next/rtw89/0001-wifi-rtw89-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "ath10k-ptp"; patch = ./net-next/ath10k/0001-wifi-ath10k-add-ptp-hardware-clock-for-tsf.patch; }
    { name = "ath11k-ptp"; patch = ./net-next/ath11k/0001-wifi-ath11k-add-ptp-hardware-clock-for-tsf.patch; }
  ];

  # KUnit test patches (must be applied after corresponding 0001 patches).
  # Each entry contains the prerequisite 0001 + the 0002 KUnit patch.
  kunitPatches = [
    { name = "mt76-kunit";  patches = [
      ./mt76/0001-wifi-mt76-add-ptp-hardware-clock-for-tsf.patch
      ./mt76/0002-wifi-mt76-add-kunit-tests-for-ptp-clock.patch
    ]; }
    { name = "ath10k-kunit"; patches = [
      ./ath10k/0001-wifi-ath10k-add-ptp-hardware-clock-for-tsf.patch
      ./ath10k/0002-wifi-ath10k-add-kunit-tests-for-ptp-clock.patch
    ]; }
    { name = "ath11k-kunit"; patches = [
      ./ath11k/0001-wifi-ath11k-add-ptp-hardware-clock-for-tsf.patch
      ./ath11k/0002-wifi-ath11k-add-kunit-tests-for-ptp-clock.patch
    ]; }
  ];

  kunitPatchesNetNext = [
    { name = "mt76-kunit";  patches = [
      ./net-next/mt76/0001-wifi-mt76-add-ptp-hardware-clock-for-tsf.patch
      ./net-next/mt76/0002-wifi-mt76-add-kunit-tests-for-ptp-clock.patch
    ]; }
    { name = "ath10k-kunit"; patches = [
      ./net-next/ath10k/0001-wifi-ath10k-add-ptp-hardware-clock-for-tsf.patch
      ./net-next/ath10k/0002-wifi-ath10k-add-kunit-tests-for-ptp-clock.patch
    ]; }
    { name = "ath11k-kunit"; patches = [
      ./net-next/ath11k/0001-wifi-ath11k-add-ptp-hardware-clock-for-tsf.patch
      ./net-next/ath11k/0002-wifi-ath11k-add-kunit-tests-for-ptp-clock.patch
    ]; }
  ];
in
{
  inherit pinnedKernelSource kernelSources driverPatches driverPatchesNetNext
          kunitPatches kunitPatchesNetNext;

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

  # ── Sequential check: verify a patch series applies cleanly ──────────
  #
  # For patches that depend on prior patches (e.g., KUnit 0002 needs 0001).
  mkSequentialPatchCheck = { name, patches, kernelSrc ? pinnedKernelSource, srcLabel ? "v6.12" }:
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
      ${lib.concatMapStringsSep "\n" (p: ''
        echo "Applying: ${p}"
        patch -p1 < ${p}
      '') patches}
      echo "PASS: ${name} applies cleanly against ${srcLabel}"
      mkdir -p $out
      echo "${name}" > $out/name
    '';

  # ── Combined check: all patches apply to the same tree ──────────────
  #
  # Applies all patches sequentially to verify they don't conflict.
  mkAllPatchesCheck = { kernelSrc ? pinnedKernelSource, srcLabel ? "v6.12", patches ? driverPatches }:
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
      '') patches}
      echo "PASS: all ${toString (builtins.length patches)} patches apply against ${srcLabel}"
      mkdir -p $out
      echo "all" > $out/name
    '';
}
