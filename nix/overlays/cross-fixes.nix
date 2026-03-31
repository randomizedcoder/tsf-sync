# Overlay to disable tests known to fail under cross-compilation.
#
# Some nixpkgs packages have test suites that don't work when cross-compiling
# (e.g., they try to run target-arch binaries on the build host).  This overlay
# disables those tests so the cross build succeeds.
final: prev: {
  boehmgc = prev.boehmgc.overrideAttrs (_: {
    doCheck = false;
  });
  libuv = prev.libuv.overrideAttrs (_: {
    doCheck = false;
  });
}
