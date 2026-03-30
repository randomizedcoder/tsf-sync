{ pkgs, rustToolchain }:

pkgs.mkShell {
  buildInputs = [
    rustToolchain
    pkgs.cargo-watch
    pkgs.cargo-nextest
  ];

  # Optional system tools for hardware testing
  nativeBuildInputs = with pkgs; [
    iw
    ethtool
    linuxPackages.perf
  ];

  RUST_BACKTRACE = "1";
}
