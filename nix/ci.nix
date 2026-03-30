{ craneLib, commonArgs, cargoArtifacts, src }:

{
  cargoFmt = craneLib.cargoFmt {
    inherit src;
  };

  cargoClippy = craneLib.cargoClippy (commonArgs // {
    inherit cargoArtifacts;
    cargoClippyExtraArgs = "-- -D warnings";
  });

  cargoTest = craneLib.cargoTest (commonArgs // {
    inherit cargoArtifacts;
  });

  cargoBuild = craneLib.buildPackage (commonArgs // {
    inherit cargoArtifacts;
  });
}
