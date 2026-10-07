# GCP Scripts

Bash (and some PowerShell) utilities for GCP work: project readiness audits, VPC/IP inventory, quotas, VPN helpers, and lab VM ops.

Auth and shell aliases live in `system-tools`. Runnable multi-step cloud jobs live here.

## Prerequisites

* **gcloud** :  Google Cloud SDK, authenticated (`gcloud auth login`) with an active project (`gcloud config set project <id>`)
* **jq** :  JSON processing (`brew install jq` on macOS)
* **curl** :  required by `gcp_check_perms.sh` / validator IAM checks
* Bash 4+ recommended for `gcp_validate_project.sh` (macOS system Bash is 3.2; use Homebrew Bash if needed)

## Layout

| Path | Purpose |
|------|---------|
| `*.sh` | Main CLI procedures (project root of this folder) |
| `vpn/` | GCP↔Azure HA VPN create / rebuild / diagnostics |
| `powershell/` | Windows/PowerShell equivalents for IPs, VMs, quotas, IAP |
| `archive/` | Older one-offs (not maintained) |
| `lib/` | Shared helpers (manifest loaders) |
| `manifests/` | Example JSON/YAML/TXT permission and port manifests |

---

## Script inventory

### Networking / inventory

| Script | Purpose |
|--------|---------|
| `gcp.list_priv_ips.sh` | Table of all reserved INTERNAL addresses in the current project |
| `gcp_check_ports.sh` | Audit VPC firewall ingress for required ports |
| `gcp.setupnewvpc.sh` | Create multi-region custom VPC (subnets, Cloud NAT, PGA, baseline firewall) |

### Project readiness

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

### List reserved internal IPs

```bash
./gcp.list_priv_ips.sh
```

### Firewall / APIs / perms / quota (standalone)

```bash
./gcp_check_apis.sh
./gcp_check_perms.sh <PROJECT_ID> [-v] [--perms manifests/permissions.example.json]
./gcp_check_ports.sh <PROJECT_ID> <VPC_NAME> [TARGET_RULE] [--ports manifests/ports.example.json]
./gcp_check_quota.sh <PROJECT_ID>

# Or via env:
# GCP_PERMS_MANIFEST=./manifests/permissions.example.yml
# GCP_PORTS_MANIFEST=./manifests/ports.example.txt
```

JSON manifests need only `jq`. YAML needs `yq` or PyYAML. Port lists also accept plain `.txt` (see `manifests/ports.example.*`).

### Project validator (with optional manifests)

```bash
./gcp_validate_project.sh [PROJECT_ID] [VPC_NAME] [SUBNET_NAME] [TARGET_RULE] [-v] \
  [--perms manifests/permissions.example.json] \
  [--ports manifests/ports.example.yml]
```

### New VPC (lab baseline)

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
# create / rebuild scripts are destructive :  review vars carefully first
```

---