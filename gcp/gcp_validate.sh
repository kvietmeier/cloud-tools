#!/bin/bash

# Usage: ./check_polaris_readiness.sh [PROJECT_ID]
PROJECT_ID=${1:-$(gcloud config get-value project)}

echo "---------------------------------------------------------"
echo " Checking Project: $PROJECT_ID for VAST Polaris Readiness"
echo "---------------------------------------------------------"

# 1. Required APIs
REQUIRED_APIS=(
    "compute.googleapis.com"
    "cloudfunctions.googleapis.com"
    "cloudbuild.googleapis.com"
    "secretmanager.googleapis.com"
    "servicenetworking.googleapis.com"
    "networkmanagement.googleapis.com"
    "artifactregistry.googleapis.com"
    "logging.googleapis.com"
    "monitoring.googleapis.com"
)

echo "[1/3] Checking Enabled APIs..."
ENABLED_APIS=$(gcloud services list --project="$PROJECT_ID" --format="value(config.name)")

for api in "${REQUIRED_APIS[@]}"; do
    if echo "$ENABLED_APIS" | grep -q "$api"; then
        echo "  ✅ $api is enabled."
    else
        echo "  ❌ $api is NOT enabled."
    fi
done

# 2. Networking Settings (Private Service Access & Firewall)
echo -e "\n[2/3] Checking Network Settings..."

# Check for Private Service Access (Required for VoC clusters)
PSA_CHECK=$(gcloud compute addresses list --global --filter="purpose=VPC_PEERING" --project="$PROJECT_ID" --format="value(name)")
if [ -z "$PSA_CHECK" ]; then
    echo "  ❌ No Private Service Access (VPC Peering) range allocated."
else
    echo "  ✅ Found Private Service Access range: $PSA_CHECK"
fi

# Check for 'voc-internal' firewall rule (VAST standard)
FW_RULE=$(gcloud compute firewall-rules list --project="$PROJECT_ID" --filter="name~voc-internal" --format="value(name)")
if [ -z "$FW_RULE" ]; then
    echo "  ⚠️  No 'voc-internal' firewall rule found. VAST clusters require specific ports (22, 2049, 443, etc.) open for internal traffic."
else
    echo "  ✅ Found VoC firewall rule: $FW_RULE"
fi

# 3. IAM Policy Check (Checks for a specific VAST service account if exists)
echo -e "\n[3/3] Checking IAM Roles (Sample Check)..."
# Checking if the current user/service account has 'Owner' or 'Editor' to perform deployment
CURRENT_ACCOUNT=$(gcloud config get-value account)
ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --format="table(bindings.role)" \
    --filter="bindings.members:$CURRENT_ACCOUNT")

if echo "$ROLES" | grep -E -q "roles/owner|roles/editor"; then
    echo "  ✅ Current account ($CURRENT_ACCOUNT) has administrative permissions."
else
    echo "  ⚠️  Current account may lack sufficient permissions to deploy VAST clusters."
fi

echo -e "\n---------------------------------------------------------"
echo "Check complete. Review '❌' or '⚠️' items before deploying."