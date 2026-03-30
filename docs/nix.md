# Nix Reference

tsf-sync is a Nix flake. All builds, development, testing, and NixOS deployment are driven through `flake.nix`.

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
```

---

## Flake Outputs

### Packages

| Target | Command | Description |
|--------|---------|-------------|
| `default` / `tsf-sync` | `nix build` | Rust CLI binary. Built with [crane](https://crane.dev/). |
| `kernel-module` | `nix build .#kernel-module` | `tsf_ptp.ko` built against `linuxPackages.kernel` (your NixOS kernel). Output at `result/lib/modules/<version>/extra/tsf_ptp.ko`. |
| `test-hwsim` | `sudo nix run .#test-hwsim` | Automated smoke test. See [Testing](#test-hwsim-smoke-test) below. |
| `test-sync` | `sudo nix run .#test-sync` | Timed sync test with counter monitoring. See [Testing](#test-sync-integration-test) below. |
| `build-kernel-module` | `nix run .#build-kernel-module` | Builds `tsf_ptp.ko` in-tree from the working directory (cleans stale artifacts first). Useful during development when `nix build .#kernel-module` caches stale `.o` files. |

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

## Testing

All test scripts require root (they load/unload kernel modules). They clean up after themselves on exit (including on Ctrl-C).

### test-hwsim (Smoke Test)

```bash
sudo nix run .#test-hwsim                    # defaults: 4 radios, 5000ns threshold
sudo nix run .#test-hwsim -- 8               # 8 radios
sudo nix run .#test-hwsim -- 4 10000         # 4 radios, 10µs threshold
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
sudo nix run .#test-sync -- 30 1000         # 30s at 1µs threshold
```

What it does:
1. Loads hwsim + tsf-ptp
2. Starts `tsf-sync start` with phc2sys sync
3. Prints `adjtime_skip_count` / `adjtime_apply_count` every 5 seconds
4. On exit: prints final counters, cleans up

Use this to compare threshold values. For example, run once at 1000ns and once at 5000ns and compare the final skip/apply ratios.

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
flake.nix                    # Top-level: wires everything together
nix/
├── package.nix              # Rust binary build (crane)
├── kernel-module.nix        # Kernel module build (stdenv + kernel.moduleBuildDependencies)
├── devshell.nix             # Development shell
├── ci.nix                   # CI checks (fmt, clippy, test, build)
├── module.nix               # NixOS service module (systemd unit + options)
└── scripts.nix              # writeShellApplication test/build scripts
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
