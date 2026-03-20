#!/bin/bash
# ==============================================================================
# VAST Data GCP Quota Specialist
# Copyright 2026 Karl Vietmeier and VAST Data
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# ==============================================================================
# SUMMARY:
# This specialist module audits Z3-Family hardware availability across GCP.
# It performs a multi-dimensional intersection check to ensure a region has
# BOTH the required Z3 CPUs (1500+) AND Z3 Local SSD storage (1PB+).
# It provides direct gcloud alpha templates for requesting quota increases.
# ==============================================================================

# ---------------------------------------------------------
# [0/3] Dependency Check
# ---------------------------------------------------------
for cmd in gcloud jq comm; do
    if ! command -v $cmd &> /dev/null; then
        echo "[FAIL] Missing dependency: $cmd"
        exit 1
    fi
done

# ---------------------------------------------------------
# [1/3] Project Initialization
# ---------------------------------------------------------
PROJECT_ID=$1
[[ -z "$PROJECT_ID" ]] && read -p "Enter GCP Project ID: " PROJECT_ID

if [ -z "$PROJECT_ID" ]; then
    echo "[FAIL] No Project ID provided. Exiting."
    exit 1
fi

MIN_Z3_CPU=1500
MIN_SSD_GB=1000000

echo "============================================================"
echo " VAST Quota Analysis: $PROJECT_ID"
echo "============================================================"

# ---------------------------------------------------------
# [2/3] Fetch & Parse Quota Data
# ---------------------------------------------------------
echo -e "\n[1/2] Fetching Global Z3 Quota Data..."
QUOTA_JSON=$(gcloud beta quotas info list --service="compute.googleapis.com" --project="$PROJECT_ID" --format="json" 2>/dev/null)

if [ -z "$QUOTA_JSON" ]; then
    echo "  [FAIL] Failed to retrieve quota JSON. Check if cloudquotas API is enabled."
    exit 1
fi

# Find regions with enough CPUs
V_CPU=$(echo "$QUOTA_JSON" | jq -r --argjson min "$MIN_Z3_CPU" '.[] | select(.metric == "compute.googleapis.com/cpus_per_vm_family") | .dimensionsInfos[]? | select(.dimensions.vm_family == "Z3" and .details.value != null) | select((.details.value | tonumber) >= $min or (.details.value | tonumber) == -1) | .applicableLocations[]' | sort)

# Find regions with enough SSDs
V_SSD=$(echo "$QUOTA_JSON" | jq -r --argjson min "$MIN_SSD_GB" '.[] | select(.metric == "compute.googleapis.com/local_ssd_total_storage_per_vm_family") | .dimensionsInfos[]? | select(.dimensions.vm_family == "Z3" and .details.value != null) | select((.details.value | tonumber) >= $min or (.details.value | tonumber) == -1) | .applicableLocations[]' | sort)

READY=$(comm -12 <(echo "$V_CPU") <(echo "$V_SSD"))

echo -e "\n[2/2] Ready Regions (CPU + SSD Match):"
if [ -z "$READY" ]; then
    echo "  [NONE] No regions meet both requirements."
else
    echo "$READY" | sed 's/^/         - /'
fi

# ---------------------------------------------------------
# [3/3] Quota Increase Command Templates
# ---------------------------------------------------------
echo -e "\n============================================================"
echo " QUOTA INCREASE TEMPLATES (Replace 'us-central1' as needed)"
echo "============================================================"

echo -e "\n# 1. Request Z3 CPUs"
echo "gcloud alpha quotas preferences create --project=$PROJECT_ID \\"
echo "  --service=compute.googleapis.com --metric=compute.googleapis.com/cpus_per_vm_family \\"
echo "  --dimensions=vm_family=Z3,location=us-central1 --preferred-value=$MIN_Z3_CPU"

echo -e "\n# 2. Request Z3 Local SSD (in GB)"
echo "gcloud alpha quotas preferences create --project=$PROJECT_ID \\"
echo "  --service=compute.googleapis.com --metric=compute.googleapis.com/local_ssd_total_storage_per_vm_family \\"
echo "  --dimensions=vm_family=Z3,location=us-central1 --preferred-value=$MIN_SSD_GB"

echo -e "\n============================================================"
echo " Analysis Complete."
echo "============================================================"
