# Deployment Guide

---

## Prerequisites

- **Linux kernel** with mac80211 support (6.1+ recommended, tested on 6.12 and 6.19)
- **linuxptp** package — provides `ptp4l`, `phc_ctl`, `pmc`
- **Root access** — kernel module loading and PTP clock access require CAP_SYS_MODULE / CAP_NET_ADMIN
- **WiFi interfaces must be up** — TSF operations require an active VIF (virtual interface). The interface doesn't need to be associated, but it must be brought up with `ip link set wlan0 up`
- **Kernel source** (for building the module) — full source tree, not just headers, because we use mac80211 internal APIs

---

## NixOS Module

### Quick Start

```nix
# flake.nix or configuration.nix
{
  services.tsf-sync = {
    enable = true;
    primaryCard = "auto";          # or "phy0" to pin a specific card
    interval = "10s";              # health check interval
    adjtimeThresholdNs = 5000;     # skip set_tsf below this (see docs/wifi-timing.md)
    logLevel = "info";             # trace, debug, info, warn, error
    loadKernelModule = true;       # auto-load tsf-ptp module
  };
}
```

### Building the Kernel Module (NixOS)

The kernel module must be built against your running kernel's source:

```nix
# nix/kernel-module.nix
{ stdenv, kernel }:

stdenv.mkDerivation {
  pname = "tsf-ptp";
  version = "0.1.0";
  src = ../kernel;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = [
    "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
  ];

  installPhase = ''
    install -D tsf_ptp.ko $out/lib/modules/${kernel.modDirVersion}/extra/tsf_ptp.ko
  '';

  meta.license = lib.licenses.gpl2Only;
}
```

### Service Module

The NixOS service module (`nix/module.nix`) provides:
- systemd service with automatic module loading
- `ptp4l` as a managed child process
- Health monitoring via `pmc`
- Clean shutdown on service stop

---

## DKMS Installation

For non-NixOS distributions (Ubuntu, Fedora, Arch, etc.):

```bash
# 1. Install prerequisites
sudo apt install linux-headers-$(uname -r) linuxptp  # Debian/Ubuntu
sudo dnf install kernel-devel linuxptp                # Fedora
sudo pacman -S linux-headers linuxptp                 # Arch

# 2. Copy source
sudo cp -r kernel/ /usr/src/tsf-ptp-0.1.0/

# 3. Register with DKMS
sudo dkms add tsf-ptp/0.1.0
sudo dkms build tsf-ptp/0.1.0
sudo dkms install tsf-ptp/0.1.0

# 4. Load the module
sudo modprobe tsf_ptp

# 5. Verify PTP clocks appeared
ls /dev/ptp*
dmesg | grep tsf-ptp
```

**Note:** DKMS builds require the full kernel source tree (not just headers) because the module includes mac80211 internal headers. You may need to install the kernel source package separately:

```bash
sudo apt install linux-source-$(uname -r | cut -d- -f1)  # Debian/Ubuntu
```

---

## Manual Installation

### Building the Kernel Module

```bash
cd kernel/

# Point KDIR at a full kernel source tree
make KDIR=/path/to/linux/source

# Verify the module was built
ls -la tsf_ptp.ko
modinfo tsf_ptp.ko
```

### Building the Rust Tool

```bash
cargo build --release
# Binary at target/release/tsf-sync
```

Or with Nix:

```bash
nix build
# Binary at result/bin/tsf-sync
```

### Running

```bash
# 1. Load the kernel module
sudo insmod kernel/tsf_ptp.ko

# 2. Verify PTP clocks
sudo ./target/release/tsf-sync discover

# 3. Generate and start ptp4l
sudo ./target/release/tsf-sync start --primary auto

# 4. Check status
sudo ./target/release/tsf-sync status

# 5. Stop
sudo ./target/release/tsf-sync stop
```

---

## Configuration

### Primary Card Selection

The primary card is the PTP grandmaster — all other cards sync to it.

- `--primary auto` (default): prefers Intel cards with native PTP (best clock quality), then falls back to the first available card
- `--primary phy0`: pin to a specific PHY name

### PTP Domain Number

tsf-sync uses domain 42 by default to avoid conflicts with other PTP deployments on the network. This only matters in multi-host configurations.

### Health Check Interval

For daemon mode, `--interval` controls how often health is checked:

```bash
sudo tsf-sync daemon --interval 5s    # responsive
sudo tsf-sync daemon --interval 30s   # less CPU overhead
```

---

## Verifying Operation

### 1. Check discovery

```bash
$ sudo tsf-sync discover
PHY        DRIVER             PTP CLOCK      STATUS
phy0       iwlwifi            /dev/ptp0      native PTP
phy1       mt76               /dev/ptp1      tsf-ptp module
phy2       mt76               /dev/ptp2      tsf-ptp module
phy3       brcmfmac           —              unsupported (FullMAC)
```

### 2. Read a PTP clock

```bash
$ sudo phc_ctl /dev/ptp1 -- get
phc_ctl[1234.567]: clock time is 1711753200.123456789
```

### 3. Check ptp4l status

```bash
$ sudo pmc -u -b 0 'GET PORT_DATA_SET'
```

### 4. Check sync health

```bash
$ sudo tsf-sync status
PORT                 STATE          HEALTH       OFFSET         PATH DELAY
001122.fffe.334455-1 MASTER         HEALTHY      —              —
001122.fffe.334455-2 SLAVE          HEALTHY      +12 ns         1.2 µs
```

---

## Troubleshooting

### Module fails to load

```
insmod: ERROR: could not insert module: Unknown symbol in module
```

The module was likely built against a different kernel version than what's running. Rebuild:

```bash
make clean
make KDIR=/lib/modules/$(uname -r)/build
```

### No PTP clocks appear

Check `dmesg`:

```bash
dmesg | grep tsf-ptp
```

Common causes:
- **"no get_tsf, skipping"**: the driver is FullMAC (brcmfmac, mwifiex) or doesn't support TSF
- **"registered 0 PTP clock(s)"**: no WiFi interfaces exist yet. Load the WiFi driver first, then load tsf-ptp
- **No wireless interfaces**: run `ip link` to verify wlan interfaces exist

### PTP ops return -ENODEV

TSF operations require an active VIF. Bring up the interface:

```bash
sudo ip link set wlan0 up
```

Check that tsf-ptp captured the VIF:

```bash
dmesg | grep "VIF up"
```

### ptp4l fails to start

- Ensure at least 2 PTP clocks are available (ptp4l needs a master and at least one slave)
- Check the generated config: `tsf-sync config`
- Check ptp4l's own logs — it's verbose about what went wrong

### Clock offsets not converging

- WiFi TSF clocks use time-stepping (no frequency discipline). Convergence is normal but may take 10-30 seconds
- Large initial offsets (seconds) are normal — ptp4l will step the clock
- If offsets stay large: check that all cards' interfaces are up and that the driver's `set_tsf` actually works (some drivers have bugs here)

### Card disappears during sync

ptp4l will log an error when a clock disappears. In daemon mode, tsf-sync will automatically detect the change and reconfigure. In one-shot mode, restart `tsf-sync start`.
