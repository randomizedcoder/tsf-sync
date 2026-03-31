# Nix Reference

tsf-sync is a Nix flake. All builds, development, testing, cross-compilation, and NixOS deployment are driven through `flake.nix`.

---

## Quick Start

```bash
# Build the Rust binary
nix build

# Build the kernel module (against your NixOS kernel)
nix build .#kernel-module

# Enter the development shell (Rust toolchain + runtime tools + kernel headers)
nix develop

# Run CI checks (fmt, clippy, test, build)
nix flake check

# Run the hwsim integration test (requires root)
sudo nix run .#test-hwsim

# MicroVM lifecycle test — no root needed, boots a full VM
nix run .#tsf-sync-lifecycle-test-basic

# Cross-compile for aarch64
nix build .#tsf-sync-aarch64-linux
```

---

## Flake Outputs

### Packages

| Target | Command | Description |
|--------|---------|-------------|
| `default` / `tsf-sync` | `nix build` | Rust CLI binary. Built with [crane](https://crane.dev/). |
| `kernel-module` | `nix build .#kernel-module` | `tsf_ptp.ko` built against `linuxPackages.kernel` (your NixOS kernel). |
| `test-hwsim` | `sudo nix run .#test-hwsim` | Automated smoke test. See [Testing](#test-hwsim-smoke-test). |
| `test-sync` | `sudo nix run .#test-sync` | Timed sync test with counter monitoring. See [Testing](#test-sync-integration-test). |
| `build-kernel-module` | `nix run .#build-kernel-module` | Builds `tsf_ptp.ko` in-tree from the working directory. |

### Cross-Compiled Packages (x86_64-linux host only)

| Target | Command | Description |
|--------|---------|-------------|
| `tsf-sync-aarch64-linux` | `nix build .#tsf-sync-aarch64-linux` | Rust binary for aarch64 (Raspberry Pi, etc.) |
| `tsf-sync-riscv64-linux` | `nix build .#tsf-sync-riscv64-linux` | Rust binary for riscv64 (Banana Pi, etc.) |
| `kernel-module-aarch64-linux` | `nix build .#kernel-module-aarch64-linux` | `tsf_ptp.ko` for aarch64 kernel |
| `kernel-module-riscv64-linux` | `nix build .#kernel-module-riscv64-linux` | `tsf_ptp.ko` for riscv64 kernel |

### MicroVM Runners

Boot a lightweight QEMU VM with `mac80211_hwsim` and `tsf_ptp.ko` preloaded. No root access needed — the VM has its own kernel. SSH in on the forwarded port for interactive use.

| Target | Command | Description |
|--------|---------|-------------|
| `tsf-sync-microvm-basic` | `nix run .#tsf-sync-microvm-basic` | 4 radios, 5000ns threshold |
| `tsf-sync-microvm-multi-radio` | `nix run .#tsf-sync-microvm-multi-radio` | 100 radios stress test |
| `tsf-sync-microvm-sync-modes` | `nix run .#tsf-sync-microvm-sync-modes` | 4 radios, kernel sync mode |

Cross-architecture VMs are also available (emulated via QEMU TCG):

| Target | Description |
|--------|-------------|
| `tsf-sync-microvm-aarch64-basic` | aarch64 VM (cortex-a72, TCG) |
| `tsf-sync-microvm-riscv64-basic` | riscv64 VM (rv64, TCG) |

The full matrix is `tsf-sync-microvm-{x86_64,aarch64,riscv64}-{basic,multi-radio,sync-modes}`.

### Lifecycle Tests

Automated phased tests that boot a VM, verify every component, and shut down cleanly. Each test runs through 14 phases and reports PASS/FAIL per phase.

| Target | Command | Description |
|--------|---------|-------------|
| `tsf-sync-lifecycle-test-basic` | `nix run .#tsf-sync-lifecycle-test-basic` | x86_64, 4 radios (~26s) |
| `tsf-sync-lifecycle-test-multi-radio` | `nix run .#tsf-sync-lifecycle-test-multi-radio` | x86_64, 100 radios (~31s) |
| `tsf-sync-lifecycle-test-sync-modes` | `nix run .#tsf-sync-lifecycle-test-sync-modes` | x86_64, kernel sync mode (~25s) |
| `tsf-sync-lifecycle-test-all` | `nix run .#tsf-sync-lifecycle-test-all` | All variants sequentially |

Cross-architecture lifecycle tests use the full `{arch}-{variant}` name:

```bash
nix run .#tsf-sync-lifecycle-test-x86_64-basic
nix run .#tsf-sync-lifecycle-test-aarch64-basic    # slow — QEMU TCG emulation
nix run .#tsf-sync-lifecycle-test-riscv64-basic     # slowest — RISC-V emulation
```

### Checks

Run all checks with `nix flake check`. These are also suitable for CI:

| Check | What it does |
|-------|-------------|
| `cargoFmt` | Verifies `cargo fmt` produces no diffs |
| `cargoClippy` | Runs `cargo clippy -- -D warnings` |
| `cargoTest` | Runs `cargo test` (unit + integration tests, hwsim tests skipped without root) |
| `cargoBuild` | Verifies the full release build succeeds |

### Development Shell

```bash
nix develop
```

Provides:

| Tool | Purpose |
|------|---------|
| Rust stable + rust-analyzer + rust-src | Rust development |
| cargo-watch, cargo-nextest | Dev workflow tools |
| linuxptp (ptp4l, phc_ctl, pmc) | Runtime PTP tools |
| iw, ethtool | WiFi diagnostics |
| kmod (modprobe, insmod, rmmod) | Module management |
| gnumake | Kernel module builds |

The shell also sets `$KDIR` to point at your kernel's build directory, so you can build the kernel module directly:

```bash
nix develop
cd kernel
make          # uses $KDIR automatically
```

### NixOS Module

```nix
# In your flake.nix inputs:
inputs.tsf-sync.url = "github:your-org/tsf-sync";

# In your NixOS configuration:
{ inputs, ... }:
{
  imports = [ inputs.tsf-sync.nixosModules.default ];

  services.tsf-sync = {
    enable = true;
    primaryCard = "auto";          # or "phy0" to pin
    interval = "10s";              # health check interval
    adjtimeThresholdNs = 5000;     # adjtime skip threshold (see docs/wifi-timing.md)
    logLevel = "info";             # trace, debug, info, warn, error
    loadKernelModule = true;       # auto-load tsf-ptp module
  };
}
```

This creates a systemd service (`tsf-sync.service`) that:
- Loads the `tsf-ptp` kernel module at boot (via `boot.extraModulePackages`)
- Starts `tsf-sync daemon` with phc2sys per secondary clock
- Restarts on failure (5-second backoff)
- Requires `CAP_SYS_RAWIO`, `CAP_SYS_TIME`, `CAP_SYS_MODULE`

---

## Cross-Compilation

Cross-compilation builds both the Rust binary and the kernel module for foreign architectures. It runs on an x86_64-linux host only.

### Supported targets

| Target | Nix cross system | Cargo target | Use case |
|--------|-----------------|--------------|----------|
| aarch64-linux | `aarch64-unknown-linux-gnu` | `aarch64-unknown-linux-gnu` | Raspberry Pi, ARM SBCs |
| riscv64-linux | `riscv64-unknown-linux-gnu` | `riscv64gc-unknown-linux-gnu` | Banana Pi, RISC-V boards |

### How it works

Cross builds use `nixpkgs` with `localSystem = "x86_64-linux"` and `crossSystem` set to the target. Two overlays keep builds fast:

- **`cross-fixes.nix`** — disables test suites that fail under cross-compilation (boehmgc, libuv try to run target binaries on the build host)
- **`cross-cache.nix`** — pins build-host-only tools (remarshal) to native packages so they hit the binary cache instead of rebuilding ~235 derivations (~2.3 GiB)

The Rust toolchain from `rust-overlay` is configured with the cross target added via `.override { targets = [ cargoTarget ]; }`. The kernel module reuses `kernel-module.nix` unchanged — `pkgsCross.linuxPackages` provides the cross-compiled kernel headers.

### Building

```bash
# Rust binary
nix build .#tsf-sync-aarch64-linux
file result/bin/tsf-sync    # ELF 64-bit LSB executable, ARM aarch64

# Kernel module
nix build .#kernel-module-aarch64-linux
file result/lib/modules/*/extra/tsf_ptp.ko    # ELF 64-bit LSB relocatable, ARM aarch64

# RISC-V
nix build .#tsf-sync-riscv64-linux
nix build .#kernel-module-riscv64-linux
```

---

## MicroVM Testing

MicroVM testing boots lightweight QEMU virtual machines with the full tsf-sync stack — `mac80211_hwsim` for simulated radios and `tsf_ptp.ko` built against the VM's kernel. This allows testing the entire stack without host root access.

Uses [astro/microvm.nix](https://github.com/astro/microvm.nix) for minimal VMs with shared `/nix/store` via 9P (no full filesystem copy).

### Architecture support

| Arch | Acceleration | Console | Speed |
|------|-------------|---------|-------|
| x86_64 | KVM | ttyS0 | Fast (~25s lifecycle) |
| aarch64 | QEMU TCG (cortex-a72) | ttyAMA0 | 2x slower |
| riscv64 | QEMU TCG (rv64) | ttyS0 | 3x slower |

### VM variants

| Variant | Radios | Threshold | Sync mode | Purpose |
|---------|--------|-----------|-----------|---------|
| `basic` | 4 | 5000ns | 0 (PTP) | Default smoke test |
| `multi-radio` | 100 | 5000ns | 0 (PTP) | Stress test |
| `sync-modes` | 4 | 5000ns | 1 (kernel) | Kernel sync loop |

### Interactive use

Boot a VM and SSH in:

```bash
# Start the VM (runs in foreground)
nix run .#tsf-sync-microvm-basic

# In another terminal, SSH into the VM
sshpass -p tsf-sync ssh -o StrictHostKeyChecking=no -p 2222 root@localhost

# Inside the VM:
modprobe mac80211_hwsim radios=4
modprobe tsf_ptp adjtime_threshold_ns=5000
tsf-sync discover
tsf-sync status
```

### What's inside the VM

Each VM is a minimal NixOS system with:
- Kernel with `mac80211_hwsim` available (stock nixpkgs `CONFIG_MAC80211_HWSIM=m`)
- `tsf_ptp.ko` built against the VM's kernel (via `boot.extraModulePackages`)
- `tsf-sync`, `linuxptp`, `kmod`, `iw`, `ethtool` in the system path
- SSH enabled with password auth (root / `tsf-sync`)
- Minimal footprint: no docs, no polkit, no nix daemon, no fonts

For cross-architecture VMs, the `cross-vm.nix` overlay disables additional test suites that fail under QEMU TCG emulation (libseccomp BPF, etc.).

---

## Lifecycle Tests

Lifecycle tests are automated phased scripts that boot a MicroVM, verify every component of the tsf-sync stack, and shut down cleanly. They require no root access and produce a PASS/FAIL report.

### Running

```bash
# Single variant (x86_64 shorthand)
nix run .#tsf-sync-lifecycle-test-basic

# Explicit arch + variant
nix run .#tsf-sync-lifecycle-test-x86_64-multi-radio

# All variants
nix run .#tsf-sync-lifecycle-test-all
```

### Phases

Each test runs through these phases in order:

| Phase | Name | Timeout (x86_64) | What it verifies |
|-------|------|-------------------|-----------------|
| 0 | Build VM | — | Nix closure already built |
| 1 | Start VM | 5s | QEMU process starts |
| 2 | Serial console | 30s | TCP port for ttyS0 opens |
| 2b | Virtio console | 45s | TCP port for hvc0 opens |
| 3 | SSH reachable | 60s | Can SSH into the VM |
| 4 | Load mac80211_hwsim | 15s | `modprobe`, verify phy count matches radios |
| 5 | Load tsf_ptp | 15s | `modprobe` with threshold and sync_mode params |
| 6 | Verify PTP clocks | 15s | Count `/sys/class/ptp/ptp*` >= expected |
| 7 | Verify sysfs params | 15s | `adjtime_threshold_ns`, skip/apply counters |
| 8 | tsf-sync discover | 15s | CLI finds all phy entries |
| 9 | Adjtime threshold | 15s | Sub-threshold adj increments skip_count; above-threshold increments apply_count |
| 10 | Sync mode check | 15s | `sync_mode` sysfs param matches variant config |
| 11 | tsf-sync status | 15s | CLI `status` command succeeds |
| 12 | Shutdown | 30s | `systemctl reboot` via SSH |
| 13 | Clean exit | 60s | QEMU process exits (VM ran with `-no-reboot`) |

Timeouts scale by architecture: aarch64 = 2x, riscv64 = 3x.

### Example output

```
========================================
  tsf-sync MicroVM Lifecycle Test
  Variant: basic | Arch: x86_64
  x86_64 (KVM accelerated)
  Radios: 4 | Threshold: 5000ns
========================================

--- Phase 0: Build VM (timeout: 600s) ---
  PASS: VM built (0ms)

--- Phase 1: Start VM (x86_64) (timeout: 5s) ---
  PASS: VM process running (PID: 12345) (112ms)
  ...
--- Phase 9: Adjtime Threshold Test (timeout: 15s) ---
  PASS: Sub-threshold adj: skip_count = 1 (1433ms)
  PASS: Above-threshold adj: apply_count = 1 (1124ms)
  ...

========================================
  ALL PHASES PASSED (16 checks)
  Arch: x86_64 | Variant: basic | Radios: 4
  Total time: 26.0s
========================================
```

---

## Testing

### test-hwsim (Smoke Test)

Requires root. Loads modules on the host directly.

```bash
sudo nix run .#test-hwsim                    # defaults: 4 radios, 5000ns threshold
sudo nix run .#test-hwsim -- 8               # 8 radios
sudo nix run .#test-hwsim -- 4 10000         # 4 radios, 10us threshold
```

What it does (~5 seconds):
1. Loads `mac80211_hwsim` with N simulated radios
2. Loads `tsf_ptp.ko` with the specified threshold
3. Verifies module parameters are exposed in sysfs
4. Runs `tsf-sync discover` to confirm PTP clocks appear
5. Tests adjtime threshold: a sub-threshold `phc_ctl adj` increments `skip_count`, an above-threshold adj increments `apply_count`
6. Tests runtime threshold change via sysfs
7. Cleans up (unloads both modules)

### test-sync (Integration Test)

```bash
sudo nix run .#test-sync                     # defaults: 30s, 5000ns threshold
sudo nix run .#test-sync -- 60              # run for 60 seconds
sudo nix run .#test-sync -- 30 1000         # 30s at 1us threshold
```

What it does:
1. Loads hwsim + tsf-ptp
2. Starts `tsf-sync start` with phc2sys sync
3. Prints `adjtime_skip_count` / `adjtime_apply_count` every 5 seconds
4. On exit: prints final counters, cleans up

### Rust Tests

```bash
# Unit tests (no root needed)
nix develop --command cargo test

# Integration tests with hwsim (requires root + modules)
sudo nix develop --command cargo test --test hwsim_test -- --ignored
```

### CI

```bash
nix flake check
```

Runs fmt, clippy, test, and build in hermetic nix builds. Suitable for GitHub Actions:

```yaml
- uses: cachix/install-nix-action@v22
- run: nix flake check
```

---

## Flake Structure

```
flake.nix                            # Top-level: wires everything together
nix/
├── package.nix                      # Rust binary build (crane)
├── kernel-module.nix                # Kernel module build (stdenv + kernel headers)
├── cross.nix                        # Cross-compilation entry point (per target)
├── devshell.nix                     # Development shell
├── ci.nix                           # CI checks (fmt, clippy, test, build)
├── module.nix                       # NixOS service module (systemd unit + options)
├── scripts.nix                      # writeShellApplication test/build scripts
├── overlays/
│   ├── cross-fixes.nix              # Disable tests failing under cross-compilation
│   ├── cross-cache.nix              # Pin host tools to native pkgs (cache hit)
│   └── cross-vm.nix                 # Disable tests failing under QEMU TCG
└── tests/
    └── microvm/
        ├── constants.nix            # Arch defs, ports, timeouts, variant config
        ├── default.nix              # Entry point: wires microvm + lifecycle
        ├── microvm.nix              # mkMicrovm: NixOS VM generator
        └── lifecycle/
            ├── default.nix          # mkFullTest: phased test script generator
            ├── lib.nix              # Shell helpers (colors, timing, SSH, WiFi)
            └── tsf-sync-checks.nix  # Domain checks (hwsim, PTP, sysfs, CLI)
```

---

## Common Tasks

### Build everything from scratch

```bash
nix build              # Rust binary
nix build .#kernel-module   # Kernel module
```

### Develop the kernel module

```bash
nix develop
cd kernel
make                   # $KDIR is already set
sudo insmod tsf_ptp.ko adjtime_threshold_ns=5000
# ... test ...
sudo rmmod tsf_ptp
```

Or use the helper that cleans stale artifacts first:

```bash
nix run .#build-kernel-module
```

### Test a threshold change without rebuilding

The threshold is a runtime sysfs parameter:

```bash
echo 10000 | sudo tee /sys/module/tsf_ptp/parameters/adjtime_threshold_ns
cat /sys/module/tsf_ptp/parameters/adjtime_threshold_ns    # verify
```

### Rebuild after kernel update

```bash
# NixOS: just rebuild
sudo nixos-rebuild switch

# Manual: rebuild the module
nix build .#kernel-module
sudo rmmod tsf_ptp
sudo insmod result/lib/modules/*/extra/tsf_ptp.ko
```

### Run on non-NixOS

The Rust binary is self-contained. The kernel module needs kernel headers:

```bash
# Build binary
nix build
cp result/bin/tsf-sync /usr/local/bin/

# Build module (needs DKMS or manual make)
cd kernel
make KDIR=/lib/modules/$(uname -r)/build
sudo insmod tsf_ptp.ko
```

See [Deployment Guide](deployment.md) for DKMS setup on Debian/Fedora/Arch.
