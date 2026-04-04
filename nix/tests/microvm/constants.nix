# Shared constants for tsf-sync MicroVM lifecycle testing.
# Architecture definitions, port allocation, timeouts, and VM variant config.
rec {
  defaults = {
    ram = 1024;
    vcpus = 2;
    sshPassword = "tsf-sync";
  };

  # ─── Architecture definitions ──────────────────────────────────────────
  architectures = {
    x86_64 = {
      nixSystem = "x86_64-linux";
      qemuMachine = "pc";
      qemuCpu = "host";
      useKvm = true;
      consoleDevice = "ttyS0";
      mem = 1024;
      vcpu = 2;
      description = "x86_64 (KVM accelerated)";
    };
    aarch64 = {
      nixSystem = "aarch64-linux";
      qemuMachine = "virt";
      qemuCpu = "cortex-a72";
      useKvm = false;
      consoleDevice = "ttyAMA0";
      mem = 1024;
      vcpu = 2;
      description = "aarch64 (ARM64, QEMU emulated)";
    };
    riscv64 = {
      nixSystem = "riscv64-linux";
      qemuMachine = "virt";
      qemuCpu = "rv64";
      useKvm = false;
      consoleDevice = "ttyS0";
      mem = 1024;
      vcpu = 2;
      description = "riscv64 (RISC-V 64-bit, QEMU emulated)";
    };
  };

  # All variants available on all architectures
  allVariantNames = builtins.attrNames variants;
  archVariants = {
    x86_64 = allVariantNames;
    aarch64 = allVariantNames;
    riscv64 = allVariantNames;
  };

  # ─── VM variants (tsf-sync-specific) ───────────────────────────────────
  variants = {
    basic = {
      portOffset = 0;
      radios = 4;
      threshold = 5000;
      syncMode = 0;
      description = "4 radios, standard 5000ns threshold — default smoke test";
    };
    multi-radio = {
      portOffset = 100;
      radios = 100;
      threshold = 5000;
      syncMode = 0;
      description = "100 radios — stress test";
    };
    sync-modes = {
      portOffset = 200;
      radios = 4;
      threshold = 5000;
      syncMode = 1;
      description = "4 radios — tests kernel sync mode (sync_mode=1)";
    };
    benchmark = {
      portOffset = 300;
      radios = 4;
      threshold = 5000;
      syncMode = 0;
      description = "benchmark VM — head-to-head C vs Rust comparison";
    };
    selftest = {
      portOffset = 400;
      radios = 4;
      threshold = 5000;
      syncMode = 0;
      selftestDuration = 60;
      description = "selftest VM — PTP kselftest + integration tests";
    };
  };

  # ─── Per-arch timeouts ─────────────────────────────────────────────────
  # KVM is fast; QEMU TCG is slower; RISC-V TCG is slowest.
  baseTimeouts = {
    ssh = 60;
    moduleLoad = 15;
    ptpClocks = 15;
    sysfsParams = 15;
    discover = 15;
    adjtimeThreshold = 15;
    syncMode = 15;
    status = 15;
    selftestQuick = 30;
    selftestLong = 120;
    shutdown = 30;
    waitExit = 60;
  };

  mkTimeouts =
    multiplier: overrides: (builtins.mapAttrs (_: v: v * multiplier) baseTimeouts) // overrides;

  timeouts = mkTimeouts 1 {
    build = 600;
    start = 5;
    serial = 30;
    virtio = 45;
  };

  timeoutsQemu = mkTimeouts 2 {
    build = 2400;
    start = 5;
    serial = 30;
    virtio = 45;
  };

  timeoutsQemuSlow = mkTimeouts 3 {
    build = 3600;
    start = 10;
    serial = 60;
    virtio = 90;
  };

  getTimeouts =
    arch:
    if architectures.${arch}.useKvm then
      timeouts
    else if arch == "riscv64" then
      timeoutsQemuSlow
    else
      timeoutsQemu;

  # ─── Port allocation ───────────────────────────────────────────────────
  # x86_64: 7000-7999, aarch64: 8000-8999, riscv64: 9000-9999
  archPortBase = {
    x86_64 = 7000;
    aarch64 = 8000;
    riscv64 = 9000;
  };

  consolePorts =
    arch: portOffset:
    let
      base = archPortBase.${arch};
      idx = portOffset / 100;
    in
    {
      serial = base + idx * 2 + 1;
      virtio = base + idx * 2 + 2;
    };

  sshForwardPort =
    arch: portOffset:
    let
      archSshBase = {
        x86_64 = 2222;
        aarch64 = 3222;
        riscv64 = 4222;
      };
    in
    archSshBase.${arch} + (portOffset / 100);

  # ─── Kernel selection ──────────────────────────────────────────────────
  getKernelPackage =
    arch: if architectures.${arch}.useKvm then "linuxPackages" else "linuxPackages_latest";

  # ─── Cross target name mapping ─────────────────────────────────────────
  archToCrossTarget = {
    aarch64 = "aarch64-linux";
    riscv64 = "riscv64-linux";
  };
}
