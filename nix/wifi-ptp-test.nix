# WiFi PTP clock integration test binary.
#
# Standalone C program exercising PTP hardware clocks via the POSIX
# clock API (clock_gettime, clock_settime, clock_adjtime). Used in
# microVM lifecycle tests against mac80211_hwsim + tsf_ptp.
#
# The source mirrors the kselftest in patch 0003 so both the in-tree
# selftest and the Nix-built binary exercise the same code paths.
#
{ stdenv, lib }:
stdenv.mkDerivation {
  pname = "wifi-ptp-test";
  version = "0.1.0";

  src = ../tests/selftests;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -D_GNU_SOURCE -O2 -Wall -Wextra -o wifi_ptp_test wifi_ptp_test.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp wifi_ptp_test $out/bin/
    runHook postInstall
  '';

  meta = {
    description = "WiFi PTP clock integration tests (TAP output)";
    license = lib.licenses.gpl2Only;
  };
}
