{
  description = "tsf-sync — synchronize WiFi TSF across many cards";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, crane, rust-overlay, flake-utils, microvm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        lib = nixpkgs.lib;
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        src = craneLib.cleanCargoSource ./.;

        commonArgs = {
          inherit src;
          strictDeps = true;
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        package = import ./nix/package.nix { inherit craneLib commonArgs cargoArtifacts; };
        checks = import ./nix/ci.nix { inherit craneLib commonArgs cargoArtifacts src; };
        devShell = import ./nix/devshell.nix { inherit pkgs rustToolchain; };

        # Kernel module built against the host's running kernel.
        # Use linuxPackages (matches the running NixOS kernel) by default.
        kernelModule = pkgs.linuxPackages.callPackage ./nix/kernel-module.nix {};

        # Helper scripts
        scripts = import ./nix/scripts.nix { inherit pkgs kernelModule package; };

        # ─── Cross-compilation (x86_64-linux host only) ────────────────
        crossTargetDefs = {
          aarch64-linux = {
            crossSystem = { config = "aarch64-unknown-linux-gnu"; };
            cargoTarget = "aarch64-unknown-linux-gnu";
          };
          riscv64-linux = {
            crossSystem = { config = "riscv64-unknown-linux-gnu"; };
            cargoTarget = "riscv64gc-unknown-linux-gnu";
          };
        };

        crossTargets = lib.optionalAttrs (system == "x86_64-linux") (
          builtins.mapAttrs (name: def: import ./nix/cross.nix {
            inherit nixpkgs crane rust-overlay system;
            inherit (def) crossSystem cargoTarget;
          }) crossTargetDefs
        );

        crossPackages = lib.concatMapAttrs (name: cross: {
          "tsf-sync-${name}" = cross.tsf-sync;
          "kernel-module-${name}" = cross.kernel-module;
        }) crossTargets;

        # ─── MicroVM + lifecycle tests (Linux only) ────────────────────
        microvmTests = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
          import ./nix/tests/microvm {
            inherit pkgs lib nixpkgs microvm crossTargets;
            tsfSync = package;
          }
        );
      in
      {
        packages = {
          default = package;
          tsf-sync = package;
          kernel-module = kernelModule;
        } // scripts // crossPackages // (microvmTests.packages or {});

        checks = checks;

        devShells.default = devShell;
      }
    ) // {
      nixosModules.default = import ./nix/module.nix self;
    };
}
