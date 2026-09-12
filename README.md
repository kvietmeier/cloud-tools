# cloud-tools

Cloud provider CLI and PowerShell **procedures** — inventory, VPC/VM cleanup, quotas, lab build-outs.
Not shell login helpers (those live in `system-tools` `bashrc.d` / PowerShell profile).

## Layout

| Path | Purpose |
|------|---------|
| `aws/` | AWS CLI scripts (instances, subnets, inventory) |
| `azure/` | Azure labs: scripts, ARM notes, AVD, diagrams (legacy AzureLabs) |
| `gcp/` | GCP CLI scripts; `gcp/powershell/` for GCP PowerShell ops |

**Boundary:** auth context and aliases → `system-tools`. Runnable multi-step cloud jobs → here.
