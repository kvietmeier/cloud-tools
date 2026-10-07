#!/bin/bash
# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0
# ==============================================================================
# GCP Firewall Port Auditor
# ==============================================================================
# Usage:
#   ./gcp_check_ports.sh [PROJECT_ID] [VPC_NAME] [TARGET_RULE] [--ports PATH]
#   GCP_PORTS_MANIFEST=./manifests/ports.example.json ./gcp_check_ports.sh
#
# Manifest: JSON, YAML, or .txt (see manifests/ports.example.*)
# ==============================================================================

_GCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/manifest.sh
source "${_GCP_DIR}/lib/manifest.sh"

PORTS_MANIFEST="${GCP_PORTS_MANIFEST:-}"
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ports|--ports-manifest)
            PORTS_MANIFEST="$2"; shift 2 ;;
        --ports=*|--ports-manifest=*)
            PORTS_MANIFEST="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [PROJECT_ID] [VPC_NAME] [TARGET_RULE] [--ports PATH]"
            echo "  --ports PATH   JSON/YAML/TXT ports manifest (or set GCP_PORTS_MANIFEST)"
            exit 0 ;;
        *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

PROJECT_ID=${POSITIONAL_ARGS[0]:-}
VPC_NAME=${POSITIONAL_ARGS[1]:-}
TARGET_RULE=${POSITIONAL_ARGS[2]:-}

[[ -z "$PROJECT_ID" ]] && read -p "Project ID: " PROJECT_ID
[[ -z "$VPC_NAME" ]] && read -p "VPC Name: " VPC_NAME
[[ -z "$TARGET_RULE" ]] && read -p "Rule Name (Blank for SCAN ALL): " TARGET_RULE

if [[ -n "$PORTS_MANIFEST" ]]; then
    load_ports_manifest "$PORTS_MANIFEST" || exit 1
else
    load_default_ports
fi

echo "============================================================"
echo " GCP Firewall Port Auditor: $PROJECT_ID"
echo " VPC: $VPC_NAME | Mode: ${TARGET_RULE:-FULL VPC SCAN}"
[[ -n "$PORTS_MANIFEST" ]] && echo " Manifest: $PORTS_MANIFEST"
echo "============================================================"

# 1. FETCH & DISCOVER
echo -e "\n[*] Identifying Active Ingress Rules in $VPC_NAME..."

if [[ -n "$TARGET_RULE" ]]; then
    RULES_JSON=$(gcloud compute firewall-rules describe "$TARGET_RULE" --project="$PROJECT_ID" --format="json" 2>/dev/null)
    [[ -z "$RULES_JSON" ]] && echo "[FAIL] Rule '$TARGET_RULE' not found." && exit 1
    RULES_JSON="[$RULES_JSON]"
else
    ALL_INGRESS=$(gcloud compute firewall-rules list --project="$PROJECT_ID" \
        --filter="direction=INGRESS AND disabled=false" --format="json")
    
    # Extract only rules belonging to this VPC and ensure they have an 'allowed' block
    RULES_JSON=$(echo "$ALL_INGRESS" | jq -c "[.[] | select(.network | contains(\"$VPC_NAME\")) | select(.allowed != null)]")
fi

# Visual Summary
echo "$RULES_JSON" | jq -r '.[] | "  -> Found: \(.name) (Allow: \(.allowed[0].IPProtocol // "none"):\(.allowed[0].ports // ["all"] | join(",")))"'

if [[ -z "$RULES_JSON" || "$RULES_JSON" == "[]" ]]; then
    echo -e "\n[ERROR] No active ingress rules detected. Audit stopped."
    exit 1
fi

check_port() {
    local proto=$1; local port=$2; local label=$3
    # Use a safer jq query that checks for array type before indexing
    MATCH=$(echo "$RULES_JSON" | jq -r ".[] | select(.allowed != null) | select(.allowed[] | select(.IPProtocol == \"$proto\") | (.ports[]? | select(. == \"$port\" or (split(\"-\") | if length==2 then (.[0]|tonumber) <= ($port|tonumber) and (.[1]|tonumber) >= ($port|tonumber) else false end)) // (. == null))) | .name" | head -n 1)
    
    if [[ -n "$MATCH" && "$MATCH" != "null" ]]; then
        printf "  [PASS] %-5s %-10s %-20s -> %s\n" "$proto" "$port" "$label" "$MATCH"
    else
        printf "  [FAIL] %-5s %-10s %-20s -> MISSING\n" "$proto" "$port" "$label"
    fi
}

echo -e "\n[*] Required Ports"
echo "------------------------------------------------------------"
for p in "${REQUIRED_PORTS[@]}"; do
    [[ -z "$p" || "$p" =~ ^[[:space:]]*# ]] && continue
    IFS=":" read -r port proto lab <<< "$p"
    check_port "$proto" "$port" "$lab"
done

echo -e "\n============================================================"
echo " Audit Complete."
echo "============================================================"
