# cloud-tools

Cloud provider CLI and PowerShell **procedures** — inventory, VPC/VM cleanup, quotas, lab build-outs.
Not shell login helpers (those live in `system-tools` `bashrc.d` / PowerShell profile).

## Layout

| Path | Purpose |
|------|---------|
| `aws/` | AWS CLI scripts (instances, subnets, inventory) |
| `azure/` | Azure labs: scripts, ARM notes, AVD, diagrams (legacy AzureLabs) |
| `gcp/` | GCP CLI scripts (project readiness, VPC/IP, quotas, VPN, lab VMs); `gcp/powershell/` for PowerShell ops. VoC troubleshooting scripts are **not** here — private `sre-runbooks` `vastcloud/scripts/`. |

**Boundary:** auth context and aliases → `system-tools`. Runnable multi-step cloud jobs → here.
