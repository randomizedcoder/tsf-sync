# Cross-compilation support — builds tsf-sync binary and kernel module for
# foreign architectures.
#
# Called once per target from flake.nix.  Reuses package.nix and
# kernel-module.nix unchanged — cross-compilation is handled by the cross pkgs.
#
# Cache optimization: build-host-only tools (remarshal, etc.) are pinned to
# the native package set via cross-cache.nix so they hit the binary cache
# instead of being rebuilt from source (~2.3 GiB saved).
{
  nixpkgs,
  crane,
  rust-overlay,
  system,
  crossSystem,
  cargoTarget,
}:

let
  # Native package set — tools from here match the binary cache hashes.
  pkgsNative = import nixpkgs { system = system; };

  pkgsCross = import nixpkgs {
    localSystem = system;
    inherit crossSystem;
    overlays = [
      (import rust-overlay)
      (import ./overlays/cross-fixes.nix)
      (import ./overlays/cross-cache.nix { inherit pkgsNative; })
    ];
  };

  rustToolchain = pkgsCross.rust-bin.stable.latest.default.override {
    extensions = [ "rust-src" ];
    targets = [ cargoTarget ];
  };

  craneLib = (crane.mkLib pkgsCross).overrideToolchain rustToolchain;

  src = craneLib.cleanCargoSource ./..;

  commonArgs = {
    inherit src;
    strictDeps = true;
    CARGO_BUILD_TARGET = cargoTarget;
    HOST_CC = "${pkgsCross.stdenv.cc.nativePrefix}cc";
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  tsf-sync = import ./package.nix { inherit craneLib commonArgs cargoArtifacts; };

  kernel-module = pkgsCross.linuxPackages.callPackage ./kernel-module.nix {};
in
{
  inherit tsf-sync kernel-module;
}
