#!/bin/bash
# ==============================================================================
#
# Copyright 2026 Karl Vietmeier
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#
# ==============================================================================
# USAGE SUMMARY
# ==============================================================================
# Script: probe_z3_highlssd_capacity.sh
# Purpose: Acts as a "stealth probe" to determine if physical Z3 High Local SSD
#          inventory is currently available in a specific GCP zone for a 
#          specified cluster size.
# 
# Execution:
#   chmod +x probe_z3_highlssd_capacity.sh
#   ./probe_z3_highlssd_capacity.sh <VM_COUNT> <ZONE>
#
# Example (Probing for an 11-node VAST cluster in us-east4-a):
#   ./probe_z3_highlssd_capacity.sh 11 us-east4-a
#
# Requirements:
#   - Authenticated gcloud CLI session
#   - Active GCP project set
#   - IAM Permissions: roles/compute.admin (or custom role)
#   - Quota: Sufficient project quota for vCPUs AND Local SSD for the Z3 family.
# ==============================================================================

set -euo pipefail

# Input Validation
if [ "$#" -ne 2 ]; then
    echo "ERROR: Missing required parameters."
    echo "USAGE: $0 <VM_COUNT> <ZONE>"
    exit 1
fi

if ! [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "ERROR: VM_COUNT must be a valid integer."
    exit 1
fi

VM_COUNT=$1
ZONE=$2
RES_NAME="z3-highlssd-probe-${VM_COUNT}n"
MACHINE_TYPE="z3-highmem-88-highlssd"

echo "Probing zone $ZONE for $VM_COUNT x $MACHINE_TYPE capacity..."

# Attempt to create the reservation
if gcloud compute reservations create $RES_NAME \
    --zone=$ZONE \
    --machine-type=$MACHINE_TYPE \
    --vm-count=$VM_COUNT \
    --require-specific-reservation \
    --quiet > /dev/null 2>&1; then
    
    echo "SUCCESS: Capacity for $VM_COUNT nodes found in $ZONE. Releasing reservation..."
    
    # Immediately delete to stop billing and release capacity
    gcloud compute reservations delete $RES_NAME \
        --zone=$ZONE \
        --quiet
else
    echo "FAILED: Insufficient capacity for $VM_COUNT nodes in $ZONE (or quota exceeded)."
    exit 1
fi