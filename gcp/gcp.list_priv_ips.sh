#!/bin/bash

###############################################################################
# Script:        list-gcp-internal-ips.sh
#
# SYNOPSIS
#     Lists all reserved INTERNAL IP addresses in the current GCP project.
#
# DESCRIPTION
#     Uses the `gcloud` CLI to retrieve all INTERNAL type reserved IPs across regions.
#     Extracts key fields like:
#         - Reservation resource name
#         - Actual attached VM (from `.users`)
#         - Subnet, Region, Purpose, Status
#
# NOTES
#     Author: Karl Vietmeier
#     Date:   2025-07-09
#     Requires: Google Cloud SDK (gcloud), jq
#
# EXAMPLE
#     ./list-gcp-internal-ips.sh
#
#     Displays a formatted table of reserved internal IP addresses in the current GCP project.
###############################################################################

# Get current GCP project
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

# Get internal addresses in JSON format
json=$(gcloud compute addresses list \
  --filter="addressType=INTERNAL" \
  --format=json)

# Count entries
COUNT=$(echo "$json" | jq length)

# Summary Header
echo ""
echo "==================== Reserved Internal IP Summary ===================="
echo "Project: $PROJECT_ID"
echo "Total Reserved Internal IPs: $COUNT"
echo "======================================================================"
echo ""

# Print header
printf "%-45s %-15s %-15s %-15s %-12s %-25s %-12s %-65s\n" \
  "Attached To VM" "Address" "Purpose" "Network" "Region" "Subnet" "Status" "Reservation Name"

# Extract and print each row
echo "$json" | jq -r '
  .[] |
  {
    reservation: .name,
    address: .address,
    attached_vm: (if (.users | type == "array" and .[0] != null) then (.users[0] | split("/") | last) else "Not Attached" end),
    purpose: .purpose,
    network: (if (.network | type == "string") then (.network | split("/") | last) else "None" end),
    region: (if (.region | type == "string") then (.region | split("/") | last) else "Global" end),
    subnet: (if (.subnetwork | type == "string") then (.subnetwork | split("/") | last) else "None" end),
    status: .status
  } |
  [.attached_vm, .address, .purpose, .network, .region, .subnet, .status, .reservation] |
  @tsv
' | while IFS=$'\t' read -r vm address purpose network region subnet status reservation; do
  printf "%-45s %-15s %-15s %-15s %-12s %-25s %-12s %-65s\n" "$vm" "$address" "$purpose" "$network" "$region" "$subnet" "$status" "$reservation"
done
