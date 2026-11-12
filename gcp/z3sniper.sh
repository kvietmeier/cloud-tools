#!/bin/bash
# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0
# ==============================================================================
# USAGE SUMMARY
# ==============================================================================
# Script: z3sniper.sh
# Purpose: Acts as a "stealth probe" to determine if physical Z3 High Local SSD
#          inventory is currently available for a specified cluster size.
#          Defaults to sweeping all us-central1 zones (current stuck region).
#
# Execution:
#   chmod +x z3sniper.sh
#   ./z3sniper.sh <VM_COUNT> [ZONE ...]
#
# Examples:
#   ./z3sniper.sh 11                  # sweep us-central1-a/b/c/f
#   ./z3sniper.sh 11 us-central1-a    # single zone
#   ./z3sniper.sh 11 us-east4-a us-east4-b
#
# Requirements:
#   - Authenticated gcloud CLI session
#   - Active GCP project set
#   - IAM Permissions: roles/compute.admin (or custom role)
#   - Quota: Sufficient project quota for vCPUs AND Local SSD for the Z3 family.
# ==============================================================================

set -euo pipefail

# Default: us-central1 zones (a, b, c, f)
DEFAULT_ZONES=(us-central1-a us-central1-b us-central1-c us-central1-f)
MACHINE_TYPE="z3-highmem-88-highlssd"

if [ "$#" -lt 1 ]; then
    echo "ERROR: Missing required parameters."
    echo "USAGE: $0 <VM_COUNT> [ZONE ...]"
    echo "  With no ZONE args, sweeps: ${DEFAULT_ZONES[*]}"
    exit 1
fi

if ! [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "ERROR: VM_COUNT must be a valid integer."
    exit 1
fi

VM_COUNT=$1
shift

if [ "$#" -gt 0 ]; then
    ZONES=("$@")
else
    ZONES=("${DEFAULT_ZONES[@]}")
fi

AVAILABLE_ZONES=()

echo "Probing ${#ZONES[@]} zone(s) for $VM_COUNT x $MACHINE_TYPE capacity..."
echo "Zones: ${ZONES[*]}"
echo "--------------------------------------------------"

for ZONE in "${ZONES[@]}"; do
    # Unique name per zone so a leftover probe does not poison the whole sweep
    RES_NAME="z3-highlssd-probe-${VM_COUNT}n-${ZONE}"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Probing $ZONE..."

    if gcloud compute reservations create "$RES_NAME" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --vm-count="$VM_COUNT" \
        --require-specific-reservation \
        --quiet > /dev/null 2>&1; then

        echo "  SUCCESS: Capacity for $VM_COUNT nodes in $ZONE. Releasing reservation..."
        gcloud compute reservations delete "$RES_NAME" \
            --zone="$ZONE" \
            --quiet
        AVAILABLE_ZONES+=("$ZONE")
    else
        echo "  FAILED: Insufficient capacity in $ZONE (or quota / name conflict)."
    fi
done

echo "--------------------------------------------------"
if [ "${#AVAILABLE_ZONES[@]}" -gt 0 ]; then
    echo "Capacity currently available in:"
    for Z in "${AVAILABLE_ZONES[@]}"; do
        echo "  - $Z"
    done
    exit 0
fi

echo "No capacity found in probed zones."
exit 1
