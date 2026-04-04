# Entry point for upstream WiFi PTP patches.
#
# Exports:
#   packages  — patch checks per driver × kernel version, plus combined checks
#   kernel    — a full kernel build with all patches applied (for microVM)
#
{ pkgs, lib }:
let
  patchLib = import ./lib.nix { inherit pkgs lib; };

  # Per-driver patch-apply checks against pinned v6.12 (backward-compat names).
  perDriverChecks = builtins.listToAttrs (map (drv:
    lib.nameValuePair "patch-check-${drv.name}" (patchLib.mkPatchCheck drv)
  ) patchLib.driverPatches);

  # Per-driver checks against stable kernel.
  perDriverChecksStable = builtins.listToAttrs (map (drv:
    lib.nameValuePair "patch-check-${drv.name}-stable" (patchLib.mkPatchCheck (drv // {
      kernelSrc = patchLib.kernelSources.stable.src;
      srcLabel = patchLib.kernelSources.stable.label;
    }))
  ) patchLib.driverPatches);

  # Per-driver checks against latest kernel.
  perDriverChecksLatest = builtins.listToAttrs (map (drv:
    lib.nameValuePair "patch-check-${drv.name}-latest" (patchLib.mkPatchCheck (drv // {
      kernelSrc = patchLib.kernelSources.latest.src;
      srcLabel = patchLib.kernelSources.latest.label;
    }))
  ) patchLib.driverPatches);

  # Per-driver checks against net-next kernel (uses net-next rebased patches).
  perDriverChecksNetNext = builtins.listToAttrs (map (drv:
    lib.nameValuePair "patch-check-${drv.name}-net-next" (patchLib.mkPatchCheck (drv // {
      kernelSrc = patchLib.kernelSources.net-next.src;
      srcLabel = patchLib.kernelSources.net-next.label;
    }))
  ) patchLib.driverPatchesNetNext);

  # Combined checks per kernel version.
  allChecks = {
    patch-check-all = patchLib.mkAllPatchesCheck {};
    patch-check-all-stable = patchLib.mkAllPatchesCheck {
      kernelSrc = patchLib.kernelSources.stable.src;
      srcLabel = patchLib.kernelSources.stable.label;
    };
    patch-check-all-latest = patchLib.mkAllPatchesCheck {
      kernelSrc = patchLib.kernelSources.latest.src;
      srcLabel = patchLib.kernelSources.latest.label;
    };
    patch-check-all-net-next = patchLib.mkAllPatchesCheck {
      kernelSrc = patchLib.kernelSources.net-next.src;
      srcLabel = patchLib.kernelSources.net-next.label;
      patches = patchLib.driverPatchesNetNext;
    };
  };

  # Per-driver full kernel builds (slow, cached).
  perDriverKernels = builtins.listToAttrs (map (drv:
    lib.nameValuePair "patch-kernel-${drv.name}" (patchLib.mkPatchedKernel drv)
  ) patchLib.driverPatches);

in
{
  packages = perDriverChecks // perDriverChecksStable // perDriverChecksLatest
    // perDriverChecksNetNext // allChecks // perDriverKernels;
  inherit (patchLib) driverPatches kernelSource kernelSources;
  patchedKernel = patchLib.mkAllPatchedKernel {};
}
