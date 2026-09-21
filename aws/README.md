# AWS Enumeration & Inventory Scripts

A collection of Bash utilities designed to quickly query and enumerate AWS networking and compute resources directly from the command line. These scripts are optimized for macOS and standard Bash environments.

## Prerequisites

Before using these scripts, ensure your system has the following installed and configured:

* **AWS CLI:** Must be installed and actively authenticated (via SSO, IAM keys, or assumed role).
* **jq:** A lightweight command-line JSON processor. On macOS, install via Homebrew: `brew install jq`
* **Bash:** Built for standard Bash environments (macOS/Linux).

## File Inventory

### Scripts

| Script | Purpose |
|---|---|
| `vpc-list-active.sh` | Enumerates VPCs/subnets/SGs. Optional region and/or VPC ID to narrow the scan. Classifies subnets as public (IGW) or private, shows AZ + free IPs, lists security groups. |
| `ip-list-persubnet.sh` | Lists all allocated IP addresses (and their ENI/Instance attachments) for a specific subnet. |
| `instances-list-persubnet.sh` | Finds EC2 instances and reports their current state (running/stopped) within a specified subnet. |
| `findami.sh` | Utility to search for and identify Amazon Machine Images (AMIs). |
| `inventory-find-instance.sh` | Searches AWS inventory to locate specific EC2 instances. |

### Configuration Files

| File | Purpose |
|---|---|
| `subnets.txt` | A batch input file containing one Subnet ID per line. Used automatically by the subnet scripts if present in the same directory. |
| `zones.txt` | A reference list of AWS Availability Zones used by the scripts. |

## Usage Examples

Most scripts in this repository support multiple input methods. For example, to list IPs in a subnet, you can use any of the following approaches:

**1. Command Line Argument:**

```bash
./ip-list-persubnet.sh subnet-0aa55e567b0ab6d0a
```