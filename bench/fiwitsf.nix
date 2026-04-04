# Nix derivation for building FiWiTSF from source.
# Used as the C baseline in head-to-head benchmarks.
{
  lib,
  stdenv,
  fetchgit,
}:
stdenv.mkDerivation {
  pname = "fiwitsf";
  version = "unstable";

  src = fetchgit {
    url = "https://git.umbernetworks.com/rjmcmahon/FiWiTSF";
    rev = "HEAD";
    hash = lib.fakeHash;
  };

  buildPhase = ''
    make
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp tsf_sync_rt_starter $out/bin/
  '';

  meta = {
    description = "FiWiTSF — WiFi TSF synchronization via debugfs (C baseline)";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
}
