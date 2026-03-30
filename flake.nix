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
  };

  outputs = { self, nixpkgs, crane, rust-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
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
      in
      {
        packages = {
          default = package;
          tsf-sync = package;
          kernel-module = kernelModule;
        } // scripts;

        checks = checks;

        devShells.default = devShell;
      }
    ) // {
      nixosModules.default = import ./nix/module.nix self;
    };
}
