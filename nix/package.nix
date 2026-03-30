{ craneLib, commonArgs, cargoArtifacts }:

craneLib.buildPackage (commonArgs // {
  inherit cargoArtifacts;
})
