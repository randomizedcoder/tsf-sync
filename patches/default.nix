# Entry point for upstream WiFi PTP patches.
#
# Exports:
#   packages  — patch-check-<driver> for each driver, plus patch-check-all
#   kernel    — a full kernel build with all patches applied (for microVM)
#
{ pkgs, lib }:
let
  patchLib = import ./lib.nix { inherit pkgs lib; };

  # Per-driver patch-apply checks (fast, no kernel build).
  perDriverChecks = builtins.listToAttrs (map (drv:
    lib.nameValuePair "patch-check-${drv.name}" (patchLib.mkPatchCheck drv)
  ) patchLib.driverPatches);

  # Combined check: all patches apply without conflict.
  allCheck = {
    patch-check-all = patchLib.mkAllPatchesCheck;
  };

  # Per-driver full kernel builds (slow, cached).
  perDriverKernels = builtins.listToAttrs (map (drv:
    lib.nameValuePair "patch-kernel-${drv.name}" (patchLib.mkPatchedKernel drv)
  ) patchLib.driverPatches);

in
{
  packages = perDriverChecks // allCheck // perDriverKernels;
  inherit (patchLib) driverPatches kernelSource;
  patchedKernel = patchLib.mkAllPatchedKernel {};
}
