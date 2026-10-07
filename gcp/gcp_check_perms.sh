#!/bin/bash
# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0
# ==============================================================================
# GCP IAM Permission Specialist
# SUMMARY:
# Audits IAM permissions. Supports a -v flag for full verbosity
# listing EVERY permission checked across all service groups.
#
# Usage:
#   ./gcp_check_perms.sh [PROJECT_ID] [-v] [--perms PATH]
#   GCP_PERMS_MANIFEST=./manifests/permissions.example.json ./gcp_check_perms.sh
#
# Manifest: JSON or YAML (see manifests/permissions.example.*)
# ==============================================================================

_GCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/manifest.sh
source "${_GCP_DIR}/lib/manifest.sh"

# ---------------------------------------------------------
# [1/4] Argument & Dependency Check
# ---------------------------------------------------------
for cmd in gcloud jq curl; do
    if ! command -v $cmd &> /dev/null; then echo "[FAIL] Missing dependency: $cmd"; exit 1; fi
done

VERBOSE=false
PERMS_MANIFEST="${GCP_PERMS_MANIFEST:-}"
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=true; shift ;;
        --perms|--permissions-manifest)
            PERMS_MANIFEST="$2"; shift 2 ;;
        --perms=*|--permissions-manifest=*)
            PERMS_MANIFEST="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [PROJECT_ID] [-v] [--perms PATH]"
            echo "  --perms PATH   JSON/YAML permissions manifest (or set GCP_PERMS_MANIFEST)"
            exit 0 ;;
        *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

PROJECT_ID=${POSITIONAL_ARGS[0]:-}
[[ -z "$PROJECT_ID" || "$PROJECT_ID" == "-v" ]] && read -p "Enter GCP Project ID: " PROJECT_ID

if [[ -n "$PERMS_MANIFEST" ]]; then
    load_permissions_manifest "$PERMS_MANIFEST" || exit 1
else
    load_default_permissions
fi

echo "============================================================"
echo " GCP IAM Permission Auditor: $PROJECT_ID"
[[ "$VERBOSE" == "true" ]] && echo " MODE: Verbose (Listing all permissions)"
[[ -n "$PERMS_MANIFEST" ]] && echo " Manifest: $PERMS_MANIFEST"
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
# [3/4] Execution & Verbose Reporting
# ---------------------------------------------------------
TOKEN=$(gcloud auth print-access-token 2>/dev/null)

for group in "${PERM_GROUP_ORDER[@]}"; do
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
