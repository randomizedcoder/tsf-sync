# Parametric MicroVM generator for tsf-sync.
#
# Uses astro/microvm.nix for minimal VMs with shared /nix/store via 9P.
# Boots mac80211_hwsim + tsf_ptp.ko for full WiFi PTP stack testing
# without host root access.
#
# Supports x86_64 (KVM), aarch64 (TCG), and riscv64 (TCG).
{
  pkgs,
  lib,
  nixpkgs,
  microvm,
  tsfSync,
  crossTargets ? {},
}:
let
  constants = import ./constants.nix;

  hostSystem = pkgs.stdenv.hostPlatform.system;

  # Overlay disabling tests that fail under QEMU cross-arch emulation
  crossEmulationOverlay = import ../../overlays/cross-vm.nix;

  # QEMU without seccomp for cross-arch (seccomp breaks TCG emulation)
  qemuWithoutSandbox = pkgs.qemu.override { seccompSupport = false; };

  archQemuArgs = {
    x86_64 = [];
    aarch64 = [];
    riscv64 = [ "-bios" "default" ];
  };

  archMachineOpts = {
    x86_64 = null;
    aarch64 = { accel = "tcg"; };
    riscv64 = { accel = "tcg"; };
  };

  mkMicrovm =
    {
      arch ? "x86_64",
      variant,
      portOffset ? 0,
      radios ? 4,
      threshold ? 5000,
      syncMode ? 0,
      ...
    }:
    let
      archCfg = constants.architectures.${arch};
      needsCross = hostSystem != archCfg.nixSystem;

      overlayedPkgs = import nixpkgs (
        if needsCross then
          {
            localSystem = hostSystem;
            crossSystem = archCfg.nixSystem;
            overlays = [ crossEmulationOverlay ];
          }
        else
          {
            system = archCfg.nixSystem;
          }
      );

      # Select correct binary for this arch
      tsfSyncForArch =
        if !needsCross then tsfSync
        else crossTargets.${constants.archToCrossTarget.${arch}}.tsf-sync;

      # Kernel module built against THIS VM's kernel
      vmKernelPackages = overlayedPkgs.${constants.getKernelPackage arch};
      tsfPtpModule = vmKernelPackages.callPackage ../../../nix/kernel-module.nix {};

      hostname = "tsf-sync-${arch}-${variant}-vm";
      consolePorts = constants.consolePorts arch portOffset;
      sshForwardPort = constants.sshForwardPort arch portOffset;

      effectiveRam = let archRam = archCfg.mem; in
        if constants.defaults.ram > archRam then constants.defaults.ram else archRam;
      effectiveVcpus = let archVcpus = archCfg.vcpu; in
        if constants.defaults.vcpus > archVcpus then constants.defaults.vcpus else archVcpus;

      nixosSystem = nixpkgs.lib.nixosSystem {
        pkgs = overlayedPkgs;

        modules = [
          microvm.nixosModules.microvm

          # Force overlayed pkgs everywhere
          (
            { lib, ... }:
            {
              _module.args.pkgs = lib.mkForce overlayedPkgs;
              nixpkgs.pkgs = lib.mkForce overlayedPkgs;
              nixpkgs.hostPlatform = lib.mkForce overlayedPkgs.stdenv.hostPlatform;
              nixpkgs.buildPlatform = lib.mkForce overlayedPkgs.stdenv.buildPlatform;
            }
          )

          (
            { config, pkgs, ... }:
            {
              system.stateVersion = "25.11";

              # ─── Minimal system for cross-arch builds ──────────────────────
              documentation.enable = !needsCross;
              documentation.man.enable = !needsCross;
              documentation.doc.enable = false;
              documentation.info.enable = false;
              documentation.nixos.enable = false;
              security.polkit.enable = false;
              programs.command-not-found.enable = false;
              fonts.fontconfig.enable = false;
              nix.enable = false;
              xdg.mime.enable = false;
              boot.supportedFilesystems = lib.mkForce [ "vfat" "ext4" ];
              hardware.enableRedistributableFirmware = false;

              # ─── MicroVM configuration ─────────────────────────────────────
              microvm = {
                hypervisor = "qemu";
                mem = effectiveRam;
                vcpu = effectiveVcpus;

                cpu = if archCfg.useKvm then null else archCfg.qemuCpu;

                shares = [
                  {
                    tag = "ro-store";
                    source = "/nix/store";
                    mountPoint = "/nix/.ro-store";
                    proto = "9p";
                  }
                ];

                volumes = [];

                interfaces = [
                  {
                    type = "user";
                    id = "eth0";
                    mac = "52:54:00:12:34:56";
                  }
                ];

                forwardPorts = [
                  {
                    from = "host";
                    host.port = sshForwardPort;
                    guest.port = 22;
                  }
                ];

                qemu = {
                  serialConsole = false;
                  machine = archCfg.qemuMachine;
                  package = if archCfg.useKvm then pkgs.qemu_kvm else qemuWithoutSandbox;

                  extraArgs = archQemuArgs.${arch} ++ [
                    "-no-reboot"
                    "-name" "${hostname},process=${hostname}"
                    "-serial" "tcp:127.0.0.1:${toString consolePorts.serial},server,nowait"
                    "-device" "virtio-serial-pci"
                    "-chardev" "socket,id=virtcon,port=${toString consolePorts.virtio},host=127.0.0.1,server=on,wait=off"
                    "-device" "virtconsole,chardev=virtcon"
                    "-append" (builtins.concatStringsSep " " (
                      [
                        "console=${archCfg.consoleDevice},115200"
                        "console=hvc0"
                        "reboot=t"
                        "panic=-1"
                        "loglevel=4"
                        "init=${config.system.build.toplevel}/init"
                      ]
                      ++ config.boot.kernelParams
                    ))
                  ];
                }
                // (if archMachineOpts.${arch} != null then { machineOpts = archMachineOpts.${arch}; } else {});
              };

              # ─── Kernel ────────────────────────────────────────────────────
              boot.kernelPackages = vmKernelPackages;
              boot.extraModulePackages = [ tsfPtpModule ];
              boot.kernelParams = [
                "console=${archCfg.consoleDevice},115200"
                "console=hvc0"
                "systemd.show_status=true"
              ];
              boot.initrd.availableKernelModules = [
                "9p" "9pnet" "9pnet_virtio"
                "virtio_pci" "virtio_console"
              ];

              # ─── Packages ──────────────────────────────────────────────────
              environment.systemPackages = [
                tsfSyncForArch
                pkgs.linuxptp
                pkgs.kmod
                pkgs.iw
                pkgs.ethtool
              ];

              # ─── SSH for lifecycle tests ───────────────────────────────────
              services.openssh = {
                enable = true;
                settings = {
                  PasswordAuthentication = lib.mkForce true;
                  PermitRootLogin = lib.mkForce "yes";
                  KbdInteractiveAuthentication = lib.mkForce true;
                };
              };
              users.users.root.password = constants.defaults.sshPassword;

              networking.hostName = hostname;
            }
          )
        ];
      };
    in
    {
      system = nixosSystem;
      runner = nixosSystem.config.microvm.declaredRunner;
      inherit arch variant radios threshold syncMode;
    };

  mkVariant =
    arch: name:
    let
      variantConfig = constants.variants.${name};
    in
    mkMicrovm (
      variantConfig
      // {
        inherit arch;
        variant = name;
      }
    );

  # Check if an architecture has the required cross-compiled binaries
  archHasBinaries =
    arch:
    let
      needsCross = hostSystem != constants.architectures.${arch}.nixSystem;
      hasCrossTargetName = constants.archToCrossTarget ? ${arch};
    in
    if !needsCross then
      true
    else
      hasCrossTargetName && crossTargets ? ${constants.archToCrossTarget.${arch}};

  availableArchitectures = lib.filterAttrs (arch: _: archHasBinaries arch) constants.architectures;

  mkArchVariants =
    arch:
    lib.mapAttrs (name: _: mkVariant arch name) (
      lib.filterAttrs (
        name: _: builtins.elem name constants.archVariants.${arch}
      ) constants.variants
    );

  variants = lib.concatMapAttrs (
    arch: _: lib.mapAttrs' (name: vm: lib.nameValuePair "${arch}-${name}" vm) (mkArchVariants arch)
  ) availableArchitectures;

in
{
  inherit mkMicrovm mkVariant constants variants;
}
