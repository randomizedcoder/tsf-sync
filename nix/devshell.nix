{ pkgs, rustToolchain }:

pkgs.mkShell {
  buildInputs = [
    rustToolchain
    pkgs.cargo-watch
    pkgs.cargo-nextest
  ];

  # System tools for testing and runtime
  nativeBuildInputs = with pkgs; [
    linuxptp       # ptp4l, phc_ctl, pmc — required at runtime
    iw
    ethtool
    kmod           # modprobe, insmod, rmmod
  ];

  RUST_BACKTRACE = "1";
}
