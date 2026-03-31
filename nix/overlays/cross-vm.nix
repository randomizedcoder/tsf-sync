# Overlay to disable tests for packages that fail under QEMU cross-architecture
# emulation. These packages build successfully but their test suites fail under
# QEMU TCG due to threading, I/O timing, or syscall emulation bugs.
#
# Used by nix/tests/microvm/microvm.nix when building aarch64/riscv64 NixOS VMs
# on an x86_64 host.
final: prev: {
  # boehm-gc: QEMU plugin bug with threading
  boehmgc = prev.boehmgc.overrideAttrs (_: {
    doCheck = false;
  });

  # libuv: I/O and event loop tests fail under QEMU emulation
  libuv = prev.libuv.overrideAttrs (_: {
    doCheck = false;
  });

  # libseccomp: seccomp BPF simulation tests fail under QEMU emulation
  libseccomp = prev.libseccomp.overrideAttrs (_: {
    doCheck = false;
  });
}
