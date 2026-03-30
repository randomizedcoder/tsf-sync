{ lib, stdenv, kernel }:

stdenv.mkDerivation {
  pname = "tsf-ptp";
  version = "0.1.0";

  src = ../kernel;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = [
    "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
  ];

  installFlags = [
    "INSTALL_MOD_PATH=${placeholder "out"}"
  ];

  installPhase = ''
    runHook preInstall
    install -D tsf_ptp.ko $out/lib/modules/${kernel.modDirVersion}/extra/tsf_ptp.ko
    runHook postInstall
  '';

  meta = {
    description = "Expose WiFi TSF timers as PTP hardware clocks";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
