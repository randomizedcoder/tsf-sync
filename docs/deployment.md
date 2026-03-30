# Deployment Guide

> **Status: Placeholder — to be completed in Phase 1**

---

## Table of Contents

- [NixOS Module](#nixos-module)
- [DKMS Installation](#dkms-installation)
- [Manual Installation](#manual-installation)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Verifying Operation](#verifying-operation)
- [Troubleshooting](#troubleshooting)

---

## NixOS Module

<!-- TODO: Document NixOS service configuration
  - services.tsf-sync.enable
  - services.tsf-sync.primaryCard
  - services.tsf-sync.interval
  - services.tsf-sync.logLevel
  - boot.extraModulePackages for tsf-ptp
  - linuxptp as a runtime dependency
-->

## DKMS Installation

<!-- TODO: Document DKMS setup for non-NixOS systems
  - Copy kernel/ to /usr/src/tsf-ptp-VERSION/
  - dkms add / build / install
  - Verify module loads
  - systemd service setup
-->

## Manual Installation

<!-- TODO: Document manual build and install
  - Building the kernel module
  - Building the Rust tool
  - Loading the module
  - Running tsf-sync
-->

## Prerequisites

<!-- TODO: Document requirements
  - Kernel version requirements
  - linuxptp package
  - Root access / capabilities
  - WiFi interface must be up (VIF requirement)
  - debugfs mounted (for fallback access)
-->

## Configuration

<!-- TODO: Document configuration options
  - Primary card selection
  - PTP domain number (avoiding conflicts)
  - Poll intervals
  - Health check thresholds
-->

## Verifying Operation

<!-- TODO: Document verification steps
  - tsf-sync discover output
  - tsf-sync status output
  - pmc queries
  - Checking clock offsets
-->

## Troubleshooting

<!-- TODO: Common issues
  - Module fails to load
  - No PTP clocks appear
  - ptp4l fails to start
  - Clock offsets not converging
  - Card disappears during sync
-->
