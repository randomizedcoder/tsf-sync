# Multi-Host Operations

> **Status: Placeholder — to be completed in Phase 2**

---

## Table of Contents

- [Overview](#overview)
- [Network Architecture](#network-architecture)
- [PTP Grandmaster Selection](#ptp-grandmaster-selection)
- [ptp4l Multi-Host Configuration](#ptp4l-multi-host-configuration)
- [GPS / Atomic Clock Integration](#gps--atomic-clock-integration)
- [Switch Configuration](#switch-configuration)
- [Monitoring Across Hosts](#monitoring-across-hosts)
- [Failure Modes & Recovery](#failure-modes--recovery)
- [Performance Characteristics](#performance-characteristics)

---

## Overview

<!-- TODO: Document the multi-host deployment model
  - N hosts, each with M WiFi cards
  - PTP over Ethernet synchronizes clocks across hosts
  - Same tsf-sync architecture per host, with ptp4l aware of network peers
  - No code changes from single-host — configuration only
-->

## Network Architecture

<!-- TODO: Document network topology
  - Dedicated management VLAN (recommended)
  - PTP multicast groups
  - Boundary clocks vs transparent clocks vs end-to-end
  - Latency budget: switch hops, cable length
-->

## PTP Grandmaster Selection

<!-- TODO: Document grandmaster strategy
  - External GPS receiver as grandmaster (best accuracy)
  - Dedicated NIC with hardware timestamping as grandmaster
  - Intel WiFi card as grandmaster (native PTP, good quality)
  - Best-master-clock algorithm and priority configuration
  - Failover: what happens when grandmaster host goes down
-->

## ptp4l Multi-Host Configuration

<!-- TODO: Document ptp4l config for multi-host
  - Adding Ethernet interface alongside WiFi PTP clocks
  - Boundary clock configuration
  - Domain number coordination across hosts
  - Per-host tsf-sync config generation
-->

## GPS / Atomic Clock Integration

<!-- TODO: Document ts2phc setup
  - GPS receiver with 1PPS output
  - ts2phc configuration
  - NIC hardware timestamping requirements
  - Accuracy expectations
-->

## Switch Configuration

<!-- TODO: Document switch requirements
  - MLD/IGMP snooping
  - PTP-aware switches (transparent clock mode)
  - VLAN configuration
  - QoS for PTP traffic
-->

## Monitoring Across Hosts

<!-- TODO: Document cross-host monitoring
  - Centralized pmc queries
  - Grafana/Prometheus metrics
  - Alerting on clock offset divergence
  - Cross-host offset comparison
-->

## Failure Modes & Recovery

<!-- TODO: Document failure scenarios
  - Network partition between hosts
  - Grandmaster host failure / failover
  - PTP convergence time after recovery
  - Coasting on last-known offset during outage
-->

## Performance Characteristics

<!-- TODO: Document expected performance
  - Cross-host accuracy with software timestamping
  - Cross-host accuracy with hardware timestamping
  - Convergence time after cold start
  - Convergence time after failover
  - Scaling limits (number of hosts, number of clocks per host)
-->
