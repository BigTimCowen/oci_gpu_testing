**GPU Operational Testing** — Interactive tool for GPU operational testing, POC stack deployments, OKE node management, custom image operations, and instance metadata inspection on Oracle Cloud Infrastructure.

**Version:** 1.0 | **Lines:** ~6,200 | **Date:** 2026-03-06

## Overview

`gpu_ops_testing.sh` — Menu-driven bash tool for GPU infrastructure POC deployments and day-2 testing operations. OCI CLI + kubectl, interactive, zero web UI required.

**POCs** (3 stack types)
Deploy OKE and Slurm POC environments via Resource Manager stacks, with a guided setup wizard for compartment creation, identity domain groups, and policy configuration

**OKE Testing** (8 operations)
Cluster and node pool listing, add nodes via instance config or manual specification, node health checks, NCCL test templates, and full node pool creation with GPU shape support

**Images** (4 operations)
Custom and platform image listing, image import from Object Storage, create images from running instances, and GPU shape compatibility tagging

**Metadata** (3 tools)
Browse IMDS endpoints, dump all instance metadata, and auto-populate `variables.sh` from instance metadata

**Compute Hosts** (multi-region scan)
Scan all subscribed regions in parallel to discover compute hosts, view distribution summary, drill into region-level host listings with state/health/shape/topology, and inspect individual host details including impacted components

**Built for daily ops:** metadata auto-discovery, response caching with configurable TTL, action logging, `--debug` mode, environment focus system (region/compartment/OKE cluster), and multi-auth support (instance principal, API key, Cloud Shell)

## Prerequisites

| Tool | Required | Notes |
|------|----------|-------|
| `oci` | Yes | OCI CLI (instance principal, API key, or cloud shell auth) |
| `kubectl` | Optional | Required for OKE testing features |
| `jq` | Yes | JSON processor |
| `curl` | Yes | For IMDS metadata queries and POC stack downloads |

## Quick Start

```bash
# Initial setup — creates variables.sh from instance metadata
./gpu_ops_testing.sh --setup

# Launch interactive menu
./gpu_ops_testing.sh --manage

# Jump directly to a section
./gpu_ops_testing.sh --manage p1    # OKE Stack POC
./gpu_ops_testing.sh --manage t1    # Add Node (Config)
./gpu_ops_testing.sh --manage i     # Images
./gpu_ops_testing.sh --manage h     # Compute Hosts

# Enable debug output
./gpu_ops_testing.sh --debug --manage
```

## Configuration

The script reads from `variables.sh` in the same directory. Run `--setup` to auto-populate from instance metadata, or configure manually:

```bash
REGION="us-ashburn-1"
TENANCY_ID="ocid1.tenancy.oc1..aaaa..."
COMPARTMENT_ID="ocid1.compartment.oc1..aaaa..."
OKE_CLUSTER_ID="ocid1.cluster.oc1..aaaa..."
```

Global options available on any invocation:

```
--compartment-id <ocid>   Override compartment
--region <region>         Override region
--debug                   Enable debug mode (verbose output)
```

---

## Menu Structure

### Top Level (`--manage`)

```
  p)  POCs              - Deploy OKE/Slurm stack POC environments
  t)  OKE Testing       - Node creation, health checks, NCCL tests
  i)  Images            - Import, create, and manage custom images
  m)  Metadata          - Browse instance metadata service (IMDS)
  h)  Compute Hosts     - Multi-region compute host scan & details

  env)   Change Focus    - Change region, compartment, OKE cluster
  q)     Quit
```

Shortcuts: `p1`, `t2`, `i`, etc. jump directly to a sub-resource.

---

### p) POCs

| Option | Function | Description |
|--------|----------|-------------|
| `p1` | OKE Stack POC | Deploy OKE HPC POC environment via Resource Manager |
| `p2` | Slurm 2.x POC | Deploy Slurm 2.x HPC POC environment |
| `p3` | Slurm 3.x POC | Deploy Slurm 3.x HPC POC environment |
| `ps` | POC Setup Wizard | Guided compartment, identity domain, group, and policy setup |

**Setup Wizard** creates: compartment, identity domain groups (GPU_Admins, GPU_Users, Network_Admins, Storage_Admins), and matching IAM policies.

---

### t) OKE Testing

| Option | Function | Description |
|--------|----------|-------------|
| `t1` | Add Node (Config) | Add node to pool using existing instance configuration |
| `t2` | Add Node (Manual) | Add node with manual shape/subnet/image specification |
| `t3` | List Clusters | List OKE clusters with status and node counts |
| `t4` | List Node Pools | List node pools with instance configs and scaling |
| `t5` | List Instance Configs | View instance configurations for node provisioning |
| `t6` | Node Health Check | GPU health, NCCL readiness, and node status checks |
| `t7` | NCCL Templates | Generate NCCL all-reduce test manifests |
| `t8` | Create Node Pool | Full node pool creation with GPU shape support |

---

### i) Images

| Option | Function | Description |
|--------|----------|-------------|
| `i1` | Custom Images | List custom images with size, state, and launch mode |
| `i2` | Platform Images | List platform images filtered by shape compatibility |
| `i3` | Import Image | Import from Object Storage URL |
| `i4` | Create from Instance | Create custom image from a running instance |

Actions: `#` (detail view), `gpu` (add GPU shape compatibility), `import` (import image)

---

### m) Metadata

| Option | Function | Description |
|--------|----------|-------------|
| `m1` | Browse IMDS | Interactive IMDS endpoint browser |
| `m2` | Dump All | Export all metadata to JSON |
| `m3` | Populate variables.sh | Auto-populate configuration from IMDS |

---

### h) Compute Hosts

| Option | Function | Description |
|--------|----------|-------------|
| `1` | Scan All Regions | Parallel scan of all subscribed regions with progress bar |
| `2` | View Region Hosts | Select a region to list hosts with state, health, shape, topology |
| `r` | Refresh | Force rescan ignoring cache |

Summary table displays only regions with active compute hosts (count > 0), showing total distribution across the tenancy.

**Host Detail View** (`#` drill-down): Name, state, health, shape, platform, AD/FD, instance ID, capacity reservation, HPC island/network block/local block topology, GPU memory fabric, impacted components, recycle status, timestamps.

Scan results are cached for 10 minutes. Regions are queried in parallel (up to `OCI_MAX_PARALLEL` concurrent calls) with a live progress bar showing completion percentage and elapsed time.

---

## Environment Focus

The environment focus system lets you scope operations without re-specifying targets:

```
env       Full environment menu (region, compartment, OKE cluster)
env c     Quick compartment change
env r     Quick region change
env oke   Quick OKE cluster change
```

Focus persists across menu navigation and is displayed in the status bar.

---

## Logging

All create/update/delete operations are:
- Displayed on screen before execution
- Logged to `logs/gpu_ops_actions_YYYYMMDD.log` with timestamps and exact commands

---

## Caching

API responses are cached in `cache/` with configurable TTL:
- OKE clusters and node pools: 5 minutes
- Instance configurations: 10 minutes
- Compute host region scan: 10 minutes
- All other resources: 60 minutes (default)

Use `r` at any menu to refresh cached data.

---

## Related

- [oci_cli_ops](https://github.com/BigTimCowen/oci_cli_ops) — Full OCI management console (compute, networking, storage, identity, operations)
