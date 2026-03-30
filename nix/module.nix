self:

{ config, lib, pkgs, ... }:

let
  cfg = config.services.tsf-sync;
  tsf-ptp-module = config.boot.kernelPackages.callPackage ./kernel-module.nix {};
in
{
  options.services.tsf-sync = {
    enable = lib.mkEnableOption "tsf-sync WiFi TSF-to-PTP bridge daemon";

    primaryCard = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = "Primary card phy name (e.g., 'phy0') or 'auto' for automatic selection.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "10s";
      description = "Health check interval.";
    };

    adjtimeThresholdNs = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 5000;
      description = "Skip set_tsf if offset is below this threshold (nanoseconds). 0 disables. Default 5000 (5µs). See docs/wifi-timing.md for tuning guidance.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "trace" "debug" "info" "warn" "error" ];
      default = "info";
      description = "Tracing log level.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.system}.default;
      description = "The tsf-sync package to use.";
    };

    loadKernelModule = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to load the tsf-ptp kernel module automatically.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure linuxptp is available for ptp4l/phc2sys/pmc
    environment.systemPackages = [ pkgs.linuxptp ];

    boot.extraModulePackages = lib.mkIf cfg.loadKernelModule [ tsf-ptp-module ];

    systemd.services.tsf-sync = {
      description = "WiFi TSF-to-PTP Bridge Daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/tsf-sync daemon --primary ${cfg.primaryCard} --interval ${cfg.interval} --adjtime-threshold-ns ${toString cfg.adjtimeThresholdNs} --log-level ${cfg.logLevel} --linuxptp-path ${pkgs.linuxptp}/bin/ptp4l";
        Restart = "on-failure";
        RestartSec = 5;

        # Needs root for:
        #   - Loading kernel modules
        #   - Accessing /dev/ptpN
        #   - Starting ptp4l (which needs CAP_SYS_TIME)
        DynamicUser = false;
        AmbientCapabilities = [ "CAP_SYS_RAWIO" "CAP_SYS_TIME" "CAP_SYS_MODULE" ];
      };
    };
  };
}
