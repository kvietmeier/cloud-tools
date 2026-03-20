#!/bin/bash
# ==============================================================================
# VAST Data GCP Pre-Flight Validator
# Copyright 2026 Karl Vietmeier and VAST Data
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# ==============================================================================
# SUMMARY:
# This tool performs a "ready-to-build" audit for VAST clusters.
# If a subnet is provided, it targets that specific region for quotas.
# If no subnet is provided, it audits ALL subnets in the VPC.
# ==============================================================================

# ---------------------------------------------------------
# [0/5] Dependency Check
# ---------------------------------------------------------
for cmd in gcloud jq comm curl; do
    if ! command -v $cmd &> /dev/null; then
        echo "[FAIL] Missing dependency: $cmd"
        exit 1
    fi
done

PROJECT_ID=$1
VPC_NAME=$2
SUBNET_NAME=$3

# Prompt for missing args
[[ -z "$PROJECT_ID" ]] && read -p "Enter Project ID: " PROJECT_ID
[[ -z "$VPC_NAME" ]] && read -p "Enter VPC Name: " VPC_NAME
[[ -z "$SUBNET_NAME" ]] && read -p "Enter Target Subnet (Leave blank for ALL): " SUBNET_NAME

echo "============================================================"
echo " VAST Full-Stack Validator: $PROJECT_ID"
echo " VPC: $VPC_NAME | Subnet: ${SUBNET_NAME:-ALL}"
echo "============================================================"

# ---------------------------------------------------------
# [1/5] Infrastructure Existence & PGA Check
# ---------------------------------------------------------
echo -e "\n[1/5] Validating Infrastructure..."
VPC_DATA=$(gcloud compute networks describe "$VPC_NAME" --project="$PROJECT_ID" --format="json" 2>/dev/null)
if [[ -z "$VPC_DATA" ]]; then
    echo "  [FAIL] VPC '$VPC_NAME' not found in $PROJECT_ID."
    exit 1
fi

if [[ -n "$SUBNET_NAME" ]]; then
    # Target Single Subnet
    SUBNET_DATA=$(gcloud compute networks subnets list --project="$PROJECT_ID" --filter="name=$SUBNET_NAME AND network~$VPC_NAME" --format="json" | jq '.[0]')
    if [[ -z "$SUBNET_DATA" || "$SUBNET_DATA" == "null" ]]; then
        echo "  [FAIL] Subnet '$SUBNET_NAME' not found in VPC '$VPC_NAME'."
        exit 1
    fi
    PGA=$(echo "$SUBNET_DATA" | jq -r '.privateIpGoogleAccess')
    S_REGION=$(echo "$SUBNET_DATA" | jq -r '.region' | awk -F'/' '{print $NF}')
    [[ "$PGA" == "true" ]] && echo "  [PASS] Subnet: $SUBNET_NAME ($S_REGION) -> PGA: ENABLED" || echo "  [FAIL] Subnet: $SUBNET_NAME ($S_REGION) -> PGA: DISABLED"
else
    # Audit All Subnets in VPC
    echo "  [INFO] No subnet provided. Auditing all subnets in '$VPC_NAME'..."
    ALL_SUBNETS=$(gcloud compute networks subnets list --project="$PROJECT_ID" --filter="network~$VPC_NAME" --format="json")
    echo "$ALL_SUBNETS" | jq -c '.[]' | while read -r sub; do
        S_NAME=$(echo "$sub" | jq -r '.name')
        S_PGA=$(echo "$sub" | jq -r '.privateIpGoogleAccess')
        S_REG=$(echo "$sub" | jq -r '.region' | awk -F'/' '{print $NF}')
        [[ "$S_PGA" == "true" ]] && echo "  [PASS] Subnet: $S_NAME ($S_REG) -> PGA: ENABLED" || echo "  [WARN] Subnet: $S_NAME ($S_REG) -> PGA: DISABLED"
    done
fi

# ---------------------------------------------------------
# [2/5] Firewall Ingress (GCP Service CIDRs)
# ---------------------------------------------------------
echo -e "\n[2/5] Probing Firewall Ingress for GCP Services..."
declare -A REQUIRED_RANGES=( ["35.191.0.0/16"]="Health Checks" ["130.211.0.0/22"]="Health Checks" ["199.36.153.8/30"]="Private Google APIs" ["35.235.240.0/20"]="IAP (SSH/AD)" ["35.199.192.0/19"]="Cloud DNS" )
CURRENT_INGRESS=$(gcloud compute firewall-rules list --project="$PROJECT_ID" --filter="network=$VPC_NAME AND direction=INGRESS" --format="value(sourceRanges.list())")

for cidr in "${!REQUIRED_RANGES[@]}"; do
    echo "$CURRENT_INGRESS" | grep -q "$cidr" && echo "  [PASS] Found: $cidr" || echo "  [FAIL] Missing: $cidr (${REQUIRED_RANGES[$cidr]})"
done

# ---------------------------------------------------------
# [3/5] Permission Probe
# ---------------------------------------------------------
echo -e "\n[3/5] Probing Identity & Permissions..."
TOKEN=$(gcloud auth print-access-token 2>/dev/null)
TEST=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" -d '{"permissions": ["compute.instances.create", "iam.serviceAccounts.actAs"]}')
[[ "$TEST" == *"compute.instances.create"* ]] && echo "  [PASS] Instance Creation Perms" || echo "  [FAIL] No Instance Creation Perms"

# ---------------------------------------------------------
# [4/5] Z3 Quota Audit
# ---------------------------------------------------------
echo -e "\n[4/5] Scanning Z3 Quotas (Global Intersection)..."
QUOTAS=$(gcloud beta quotas info list --service="compute.googleapis.com" --project="$PROJECT_ID" --format="json" 2>/dev/null)

if [[ -n "$QUOTAS" ]]; then
    V_CPU=$(echo "$QUOTAS" | jq -r '.[] | select(.metric == "compute.googleapis.com/cpus_per_vm_family") | .dimensionsInfos[]? | select(.dimensions.vm_family == "Z3" and (.details.value|tonumber) >= 1500) | .applicableLocations[]' | sort)
    V_SSD=$(echo "$QUOTAS" | jq -r '.[] | select(.metric == "compute.googleapis.com/local_ssd_total_storage_per_vm_family") | .dimensionsInfos[]? | select(.dimensions.vm_family == "Z3" and (.details.value|tonumber) >= 1000000) | .applicableLocations[]' | sort)
    READY=$(comm -12 <(echo "$V_CPU") <(echo "$V_SSD"))

    if [[ -z "$READY" ]]; then
        echo "  [FAIL] No regions meet Z3 requirements."
    else
        echo "  [PASS] Ready Regions: $(echo $READY | tr '\n' ' ')"
        # If a target subnet was provided, specifically verify its region
        if [[ -n "$S_REGION" ]]; then
             echo "$READY" | grep -q "$S_REGION" && echo "  [PASS] Target Region '$S_REGION' is fully provisioned." || echo "  [FAIL] Target Region '$S_REGION' lacks Z3 quota."
        fi
    fi
fi

# ---------------------------------------------------------
# [5/5] Remediations
# ---------------------------------------------------------
TARGET_LOC=${S_REGION:-"us-central1"}
echo -e "\n============================================================"
echo " QUOTA INCREASE TEMPLATE (Target: $TARGET_LOC)"
echo "============================================================"
echo "gcloud alpha quotas preferences create --project=$PROJECT_ID \\"
echo "  --service=compute.googleapis.com --metric=compute.googleapis.com/cpus_per_vm_family \\"
echo "  --dimensions=vm_family=Z3,location=$TARGET_LOC --preferred-value=1500"

echo -e "\ngcloud alpha quotas preferences create --project=$PROJECT_ID \\"
echo "  --service=compute.googleapis.com --metric=compute.googleapis.com/local_ssd_total_storage_per_vm_family \\"
echo "  --dimensions=vm_family=Z3,location=$TARGET_LOC --preferred-value=1000000"

echo -e "\n============================================================"
echo " Validation Complete."
echo "============================================================"
