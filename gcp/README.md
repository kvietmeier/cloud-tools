# GCP Scripts

Bash (and some PowerShell) utilities for **VAST on Cloud** GCP work: project readiness audits, VPC/IP inventory, VoC VIP/alias attach debugging, quotas, VPN helpers, and lab VM ops.

Auth and shell aliases live in `system-tools`. Runnable multi-step cloud jobs live here.

## Prerequisites

* **gcloud** — Google Cloud SDK, authenticated (`gcloud auth login`) with an active project (`gcloud config set project <id>`)
* **jq** — JSON processing (`brew install jq` on macOS)
* **python3** — required by `gcp.voc_alias_attach_audit.sh` / `gcp.voc_ip_orphan_scan.sh`
* **curl** — required by `gcp_check_perms.sh` / validator IAM checks
* Bash 4+ recommended for `gcp_validate_project.sh` (macOS system Bash is 3.2; use Homebrew Bash if needed)

## Layout

| Path | Purpose |
|------|---------|
| `*.sh` | Main CLI procedures (project root of this folder) |
| `vpn/` | GCP↔Azure HA VPN create / rebuild / diagnostics |
| `powershell/` | Windows/PowerShell equivalents for IPs, VMs, quotas, IAP |
| `archive/` | Older validators / one-offs (not maintained) |

---

## Script inventory

### VoC / networking diagnostics

| Script | Purpose |
|--------|---------|
| `gcp.voc_alias_attach_audit.sh` | **Per-cluster** audit: reserved VIP/internal IPs vs eNode aliases, Compute ops, Cloud Audit Logs, optional **cloud_cli** ops-agent lines; forensics note in `docs/voc-gcp-alias-attach-forensics.md` |
| `gcp.voc_ip_orphan_scan.sh` | **Project-wide**: group `GCE_ENDPOINT` INTERNAL IPs by cluster prefix and mark **ORPHAN** (RESERVED, no live VMs) vs **LIVE** |
| `gcp.list_priv_ips.sh` | Table of all reserved INTERNAL addresses in the current project |
| `gcp_check_ports.sh` | Audit VPC firewall ingress for VAST protocol/fabric ports |
| `gcp.setupnewvpc.sh` | Create multi-region custom VPC (subnets, Cloud NAT, PGA, baseline firewall) |

### Project readiness (VAST on Cloud)

| Script | Purpose |
|--------|---------|
| `gcp_validate_project.sh` | Full ready-to-build audit: APIs, VPC/subnets/PGA, CIDR ingress, firewall, IAM, Z3 quota |
| `gcp_check_apis.sh` | Check required GCP APIs are enabled |
| `gcp_check_perms.sh` | IAM permission audit (`-v` for verbose) |
| `gcp_check_quota.sh` | Z3 CPU + Local SSD quota intersection by region |

### Compute / storage / capacity

| Script | Purpose |
|--------|---------|
| `gcp_manage_vms.sh` | Sourceable helper: start/stop/resume/list lab or gateway client VMs in parallel |
| `gcp_create_share_bucket.sh` | Create a public GCS share bucket (drivers/ISOs) |
| `z3sniper.sh` | Probe whether Z3 High Local SSD capacity exists in a zone for N VMs |
| `check_tpu_avail.sh` | TPU calendar-mode availability (edit params at top of script) |

### VPN (`vpn/`)

| Script | Purpose |
|--------|---------|
| `vpn_create_2_azure.sh` / `vpn_create_2_azure_2.sh` | Create GCP side of HA VPN to Azure (edit embedded config) |
| `vpn_rebuild_tunnels.sh` | Tear down / rebuild VPN tunnels + BGP peers |
| `vpn_checkazure_setup.sh` | Tunnel / BGP diagnostic |

### PowerShell (`powershell/`)

Private IP reserve/list/delete, VM start/stop, quotas, firewall updates, IAP proxy, instance listing. Edit `$ProjectId` / region vars at the top of each script before running.

---

## Usage

Most scripts use the **current gcloud project**. Confirm first:

```bash
gcloud config get-value project
gcloud config get-value account
```

### VoC alias-attach audit (cluster name is required)

Use when a cluster has reserved VIPs but eNodes are missing aliases (often `Invalid fingerprint` from concurrent NIC updates). Nodes are identified by network tag **`voc-internal`** (Polaris puts it on every cluster node) plus `labels.cluster_name` or name prefix. **DNS VIP:** absent or reserved-until-DNS-enabled is OK (`[3b]`). Exit **2** if other reserved VIP/internal IPs are missing from NICs on a live cluster (gaps + remediation at top of `[3]` / `[6]`). Exit **3** if no live (RUNNING/STAGING) nodes but `RESERVED` addresses remain (orphan leak).

```bash
cd gcp
chmod +x gcp.voc_alias_attach_audit.sh   # once

# CLUSTER_NAME is the first argument
./gcp.voc_alias_attach_audit.sh seb-wmt-test

./gcp.voc_alias_attach_audit.sh eiki-vko-gcp-1 \
  -p vast-on-cloud \
  -z europe-west1-c

./gcp.voc_alias_attach_audit.sh some-ci-cluster \
  --since 2026-09-20 \
  --json-dir /tmp/voc-audit-some-ci-cluster

# Faster: skip Cloud Audit Logs
./gcp.voc_alias_attach_audit.sh seb-wmt-test --no-logs
```

| Flag | Meaning |
|------|---------|
| `-p, --project` | GCP project (default: active config) |
| `-z, --zone` | Limit instances/ops to one zone |
| `-s, --since` | Ops/logs since `YYYY-MM-DD` or RFC3339 (default: yesterday) |
| `--no-logs` | Skip `gcloud logging read` |
| `--json-dir DIR` | Dump raw JSON (addresses, instances, ops, audit) |

Manual fix pattern (full alias set in **one** update — do not parallelize per-VIP):

```bash
gcloud compute instances network-interfaces update <ENODE_VM> \
  --zone=<ZONE> \
  --network-interface=nic0 \
  --aliases='10.x.x.x/32;10.x.x.y/32;...'
```

### Project-wide orphan VIP / IP scan

When a project has a long list of `IN_USE` / `RESERVED` `GCE_ENDPOINT` addresses and you need to know which clusters are still up vs teardown leaks:

```bash
./gcp.voc_ip_orphan_scan.sh
./gcp.voc_ip_orphan_scan.sh -p vast-on-cloud --orphans-only --delete-cmds
```

| Flag | Meaning |
|------|---------|
| `-p, --project` | GCP project (default: active config) |
| `--all-internal` | All INTERNAL addresses (not only `purpose=GCE_ENDPOINT`) |
| `--orphans-only` | Only print ORPHAN clusters |
| `--delete-cmds` | Print commented `gcloud compute addresses delete` lines |
| `--json-dir DIR` | Dump raw addresses / instances JSON |

Exit **3** if any ORPHAN groups exist. For one cluster’s NIC/alias deep dive, use `gcp.voc_alias_attach_audit.sh`.

### List reserved internal IPs

```bash
./gcp.list_priv_ips.sh
```

### Project validator

```bash
./gcp_validate_project.sh [PROJECT_ID] [VPC_NAME] [SUBNET_NAME] [TARGET_RULE] [-v]
# Omitting args prompts interactively. -v lists every IAM permission checked.
```

### Firewall / APIs / perms / quota (standalone)

```bash
./gcp_check_apis.sh
./gcp_check_perms.sh <PROJECT_ID> [-v]
./gcp_check_ports.sh <PROJECT_ID> <VPC_NAME> [TARGET_RULE]
./gcp_check_quota.sh <PROJECT_ID>
```

### New VoC-style VPC

```bash
./gcp.setupnewvpc.sh
# Edit region/CIDR variables in the script before running; needs network admin rights.
```

### Z3 capacity probe

```bash
./z3sniper.sh <VM_COUNT> <ZONE>
# Example: ./z3sniper.sh 11 us-east4-a
```

### Public share bucket

```bash
./gcp_create_share_bucket.sh [BUCKET_NAME] [LOCATION] [UPLOAD_DIR]
```

### Manage lab/gateway VMs

```bash
# Source the file, then call the function:
source ./gcp_manage_vms.sh
gcp_manage_client_vms list
gcp_manage_client_vms start 5 lab
gcp_manage_client_vms stop gateway
```

### VPN helpers

Edit project/VPC/ASN/APIPA values inside the scripts under `vpn/`, then:

```bash
./vpn/vpn_checkazure_setup.sh
# create / rebuild scripts are destructive — review vars carefully first
```

---

## Notes

* `vast_ports.txt` — reference port list used by firewall audits.
* Sample audit output may appear as `vast_gcp_audit_*.txt`; those are run artifacts, not inputs.
* Prefer `gcp_validate_project.sh` over anything under `archive/`.
