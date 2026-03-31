# Entry point for MicroVM lifecycle testing.
# Generates all microVM runner packages and lifecycle tests.
#
# Supports x86_64 (KVM), aarch64 (TCG), and riscv64 (TCG) architectures.
{
  pkgs,
  lib,
  nixpkgs,
  microvm,
  tsfSync,
  crossTargets ? {},
}:
let
  constants = import ./constants.nix;

  microvmLib = import ./microvm.nix {
    inherit
      pkgs
      lib
      nixpkgs
      microvm
      tsfSync
      crossTargets
      ;
  };

  lifecycle = import ./lifecycle {
    inherit pkgs lib constants;
    inherit (microvmLib) mkMicrovm;
    microvmVariants = microvmLib.variants;
  };

in
{
  packages =
    lifecycle.packages
    # VM runners: tsf-sync-microvm-<arch>-<variant>
    // lib.mapAttrs' (
      name: vm: lib.nameValuePair "tsf-sync-microvm-${name}" vm.runner
    ) microvmLib.variants
    # Backwards-compat aliases: tsf-sync-microvm-<variant> → x86_64 variant
    // lib.mapAttrs' (
      n: v: lib.nameValuePair "tsf-sync-microvm-${lib.removePrefix "x86_64-" n}" v.runner
    ) (lib.filterAttrs (n: _: lib.hasPrefix "x86_64-" n) microvmLib.variants);
}
