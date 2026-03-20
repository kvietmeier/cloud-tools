#!/bin/bash
# ==============================================================================
# VAST Data GCP IAM Permission Specialist
# Copyright 2026 Karl Vietmeier and VAST Data
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# ==============================================================================
# SUMMARY:
# Audits vAST on Cloud IAM permissions. Supports a -v flag for full verbosity
# listing EVERY permission checked across all service groups.
# ==============================================================================

# ---------------------------------------------------------
# [1/4] Argument & Dependency Check
# ---------------------------------------------------------
for cmd in gcloud jq curl; do
    if ! command -v $cmd &> /dev/null; then echo "[FAIL] Missing dependency: $cmd"; exit 1; fi
done

PROJECT_ID=$1
VERBOSE=false

for arg in "$@"; do
    if [[ "$arg" == "-v" || "$arg" == "--verbose" ]]; then VERBOSE=true; fi
done

[[ -z "$PROJECT_ID" || "$PROJECT_ID" == "-v" ]] && read -p "Enter GCP Project ID: " PROJECT_ID

echo "============================================================"
echo " VAST IAM Permission Auditor: $PROJECT_ID"
[[ "$VERBOSE" == "true" ]] && echo " MODE: Verbose (Listing all permissions)"
echo "============================================================"

# ---------------------------------------------------------
# [2/4] Identity & Primitive Role Check
# ---------------------------------------------------------
CURRENT_AUTH=$(gcloud config get-value core/account 2>/dev/null)
echo "[*] Identity: $CURRENT_AUTH"

PRIMITIVE_CHECK=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:$CURRENT_AUTH AND (bindings.role:roles/owner OR bindings.role:roles/editor)" \
    --format="value(bindings.role)" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

if [[ -n "$PRIMITIVE_CHECK" ]]; then
    echo "    [BYPASS] Privileges: $PRIMITIVE_CHECK"
    echo "             Owner/Editor roles override granular failures."
else
    echo "    [INFO] No Primitive Role detected. Checking granular perms."
fi

# ---------------------------------------------------------
# [3/4] Permission Groups
# ---------------------------------------------------------
declare -A PERM_GROUPS=(
    ["Cloud Functions"]="cloudfunctions.functions.create cloudfunctions.functions.delete cloudfunctions.functions.get cloudfunctions.functions.getIamPolicy cloudfunctions.functions.setIamPolicy cloudfunctions.operations.get"
    ["Compute Engine"]="compute.addresses.createInternal compute.addresses.deleteInternal compute.addresses.get compute.addresses.setLabels compute.addresses.useInternal compute.disks.create compute.disks.setLabels compute.healthChecks.create compute.healthChecks.delete compute.healthChecks.get compute.healthChecks.use compute.images.get compute.images.useReadOnly compute.instanceGroupManagers.create compute.instanceGroupManagers.delete compute.instanceGroupManagers.get compute.instanceGroups.create compute.instanceGroups.delete compute.instanceGroups.get compute.instanceTemplates.create compute.instanceTemplates.delete compute.instanceTemplates.get compute.instanceTemplates.useReadOnly compute.instances.create compute.instances.get compute.instances.setLabels compute.instances.setMetadata compute.instances.setTags compute.regionOperations.get compute.subnetworks.get compute.subnetworks.use compute.resourcePolicies.create compute.resourcePolicies.delete compute.resourcePolicies.get"
    ["IAM & SAs"]="iam.roles.create iam.roles.delete iam.roles.get iam.roles.undelete iam.serviceAccounts.actAs iam.serviceAccounts.create iam.serviceAccounts.delete iam.serviceAccounts.get"
    ["Resource Manager"]="resourcemanager.projects.get resourcemanager.projects.getIamPolicy resourcemanager.projects.setIamPolicy"
    ["Secret Manager"]="secretmanager.secrets.create secretmanager.secrets.delete secretmanager.secrets.get secretmanager.versions.access secretmanager.versions.add secretmanager.versions.destroy secretmanager.versions.enable secretmanager.versions.get"
    ["Cloud Storage"]="storage.buckets.create storage.buckets.delete storage.buckets.get storage.objects.create storage.objects.delete storage.objects.get"
)

# ---------------------------------------------------------
# [4/4] Execution & Verbose Reporting
# ---------------------------------------------------------
TOKEN=$(gcloud auth print-access-token 2>/dev/null)
ORDER=("Cloud Functions" "Compute Engine" "IAM & SAs" "Resource Manager" "Secret Manager" "Cloud Storage")

for group in "${ORDER[@]}"; do
    echo -e "\n[*] Auditing $group..."
    
    JSON_ARRAY=$(echo ${PERM_GROUPS[$group]} | jq -R -c 'split(" ")')
    RESPONSE=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" -d "{\"permissions\": $JSON_ARRAY}")

    MISSING_COUNT=0
    for p in ${PERM_GROUPS[$group]}; do
        if [[ "$RESPONSE" == *"$p"* ]]; then
            if [ "$VERBOSE" = true ]; then echo "    [+] $p"; fi
        else
            if [ "$VERBOSE" = true ]; then echo "    [-] $p"; fi
            ((MISSING_COUNT++))
        fi
    done

    if [ $MISSING_COUNT -eq 0 ]; then
        echo "    [PASS] All $(echo ${PERM_GROUPS[$group]} | wc -w) permissions verified."
    else
        if [[ -n "$PRIMITIVE_CHECK" ]]; then
            echo "    [NOTE] API reported $MISSING_COUNT missing permissions (Overridden by $PRIMITIVE_CHECK)."
        else
            echo "    [FAIL] Missing $MISSING_COUNT permission(s)."
        fi
    fi
done

echo -e "\n============================================================"
echo " Audit Complete."
echo "============================================================"