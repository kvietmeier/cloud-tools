#!/bin/bash
# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0
# ==============================================================================
# GCP Master Validator (Combined & Modular)
# ==============================================================================
# SUMMARY:
#   This tool performs a comprehensive "ready-to-build" audit for 
#   Google Cloud. It validates APIs, network infrastructure (VPC, Subnets, PGA),
#   GCP Service CIDR ingress, firewall rules, IAM permissions,
#   and Z3 hardware quota availability.
#
# USAGE:
#   * Ensure gcloud CLI is installed
#   * ProjectID can be provided as an argument or will default to the active gcloud project.
#
#   ./gcp_validate_project.sh [PROJECT_ID] [VPC_NAME] [SUBNET_NAME] [TARGET_RULE] [-v]
#     [--perms PATH] [--ports PATH]
#     - If arguments are omitted, the script will prompt interactively.
#     - Use -v or --verbose to list all permissions during the IAM check.
#     - --perms / --ports: JSON, YAML, or (ports) TXT manifests; see manifests/*.example.*
#     - Or set GCP_PERMS_MANIFEST / GCP_PORTS_MANIFEST.
# ==============================================================================

_GCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/manifest.sh
source "${_GCP_DIR}/lib/manifest.sh"

# ---------------------------------------------------------
# Preflight Check: Bash Version + Dependencies
# ---------------------------------------------------------
preflight_check() {
    REQUIRED_BASH_MAJOR=4

    # ---- Bash Version Enforcement ----
    if [[ -z "${BASH_VERSINFO[*]}" ]]; then
        echo "[FAIL] Unable to determine Bash version."
        exit 1
    fi

    CURRENT_BASH_MAJOR="${BASH_VERSINFO[0]}"

    if [[ "$CURRENT_BASH_MAJOR" -lt "$REQUIRED_BASH_MAJOR" ]]; then
        echo "[WARN] Detected Bash $BASH_VERSION (requires >= 4.0)"

        CANDIDATES=(
            /opt/homebrew/bin/bash
            /usr/local/bin/bash
            /usr/bin/bash
            /bin/bash
        )

        for NEW_BASH in "${CANDIDATES[@]}"; do
            if [[ -x "$NEW_BASH" ]]; then
                VERSION=$("$NEW_BASH" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)
                if [[ "$VERSION" -ge "$REQUIRED_BASH_MAJOR" ]]; then
                    echo "[INFO] Re-executing with compatible Bash: $NEW_BASH (v$VERSION)"
                    exec "$NEW_BASH" "$0" "$@"
                fi
            fi
        done

        echo ""
        echo "[FAIL] No compatible Bash (>= 4.0) found."
        echo ""
        echo "Fix:"
        echo "  macOS:  brew install bash"
        echo "          /opt/homebrew/bin/bash $0 $@"
        echo ""
        echo "  Ubuntu/Debian: sudo apt-get install bash"
        echo "  RHEL/CentOS:   sudo yum install bash"
        echo ""
        exit 1
    fi

    # ---- Dependency Checks ----
    echo "[*] Running preflight checks..."
    for cmd in gcloud jq comm curl; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "[FAIL] Missing dependency: $cmd"
            exit 1
        else
            echo "  [PASS] Found: $cmd"
        fi
    done
}



# ---------------------------------------------------------
# Global Setup & Argument Parsing
# ---------------------------------------------------------

VERBOSE=false
PERMS_MANIFEST="${GCP_PERMS_MANIFEST:-}"
PORTS_MANIFEST="${GCP_PORTS_MANIFEST:-}"
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=true; shift ;;
        --perms|--permissions-manifest)
            PERMS_MANIFEST="$2"; shift 2 ;;
        --perms=*|--permissions-manifest=*)
            PERMS_MANIFEST="${1#*=}"; shift ;;
        --ports|--ports-manifest)
            PORTS_MANIFEST="$2"; shift 2 ;;
        --ports=*|--ports-manifest=*)
            PORTS_MANIFEST="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [PROJECT_ID] [VPC_NAME] [SUBNET_NAME] [TARGET_RULE] [-v] [--perms PATH] [--ports PATH]"
            exit 0 ;;
        *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

PROJECT_ID=${POSITIONAL_ARGS[0]:-}
VPC_NAME=${POSITIONAL_ARGS[1]:-}
SUBNET_NAME=${POSITIONAL_ARGS[2]:-}
TARGET_RULE=${POSITIONAL_ARGS[3]:-}

if [[ -z "$PROJECT_ID" ]]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
fi

[[ -z "$PROJECT_ID" ]] && read -p "Enter Project ID: " PROJECT_ID
[[ -z "$VPC_NAME" ]] && read -p "Enter VPC Name: " VPC_NAME
[[ -z "$SUBNET_NAME" ]] && read -p "Enter Subnet where Cluster will be Installed (Leave blank for ALL): " SUBNET_NAME
[[ -z "$TARGET_RULE" ]] && read -p "Firewall Rule Name to Check (Leave blank for FULL VPC SCAN): " TARGET_RULE

if [[ -z "$PROJECT_ID" ]]; then
    echo "[FAIL] No Project ID provided. Exiting."
    exit 1
fi

if [[ -n "$PERMS_MANIFEST" ]]; then
    load_permissions_manifest "$PERMS_MANIFEST" || exit 1
else
    load_default_permissions
fi

if [[ -n "$PORTS_MANIFEST" ]]; then
    load_ports_manifest "$PORTS_MANIFEST" || exit 1
else
    load_default_ports
fi

# ---------------------------------------------------------
# Optional File Logging Feature
# ---------------------------------------------------------
read -p "Would you like to save this audit output to a log file? (y/N): " SAVE_LOG
if [[ "$SAVE_LOG" =~ ^[Yy]$ ]]; then
    LOG_FILE="gcp_audit_${PROJECT_ID}_$(date +%Y%m%d_%H%M%S).log"
    echo "Logging all output to $LOG_FILE..."
    # This pipes all terminal output to the log file without changing any echo commands
    exec > >(tee -i "$LOG_FILE")
    exec 2>&1
fi

echo -e "\n========================================================================"
echo " GCP Requirements Validator Using Project: $PROJECT_ID"
echo " VPC: $VPC_NAME | Subnet: ${SUBNET_NAME:-ALL}"
echo " Rule: ${TARGET_RULE:-FULL VPC SCAN}"
[[ "$VERBOSE" == "true" ]] && echo " MODE: Verbose (Listing all permissions)"
[[ -n "$PERMS_MANIFEST" ]] && echo " Perms manifest: $PERMS_MANIFEST"
[[ -n "$PORTS_MANIFEST" ]] && echo " Ports manifest: $PORTS_MANIFEST"
echo "========================================================================"

# ---------------------------------------------------------
# Function: API Checks
# ---------------------------------------------------------
check_apis() {
    REQUIRED_SERVICES=(
        "servicenetworking.googleapis.com"
        "cloudfunctions.googleapis.com"
        "artifactregistry.googleapis.com"
        "cloudbuild.googleapis.com"
        "compute.googleapis.com"
        "networkmanagement.googleapis.com"
        "networksecurity.googleapis.com"
        "monitoring.googleapis.com"
        "logging.googleapis.com"
        "secretmanager.googleapis.com"
    )
    ENABLED_SERVICES=$(gcloud services list --enabled --format="value(config.name)")

    echo -e "\n[*] Checking enabled Google Cloud APIs..."
    echo "------------------------------------------------------------"
    for SERVICE in "${REQUIRED_SERVICES[@]}"; do
        if echo "$ENABLED_SERVICES" | grep -q "$SERVICE"; then
            echo "  [PASS] $SERVICE is enabled."
        else
            echo "  [FAIL] $SERVICE is NOT enabled!"
        fi
    done
    echo ""
}

# ---------------------------------------------------------
# Function: Infrastructure Existence & PGA Check
# ---------------------------------------------------------
check_infrastructure() {
    echo -e "\n[*] Validating Infrastructure..."
    echo "------------------------------------------------------------"
    VPC_DATA=$(gcloud compute networks describe "$VPC_NAME" --project="$PROJECT_ID" --format="json" 2>/dev/null)
    if [[ -z "$VPC_DATA" ]]; then
        echo "  [FAIL] VPC '$VPC_NAME' not found in $PROJECT_ID."
        exit 1
    fi

    if [[ -n "$SUBNET_NAME" ]]; then
        SUBNET_DATA=$(gcloud compute networks subnets list --project="$PROJECT_ID" --filter="name=$SUBNET_NAME AND network~$VPC_NAME" --format="json" | jq '.[0]')
        if [[ -z "$SUBNET_DATA" || "$SUBNET_DATA" == "null" ]]; then
            echo "  [FAIL] Subnet '$SUBNET_NAME' not found in VPC '$VPC_NAME'."
            exit 1
        fi
        PGA=$(echo "$SUBNET_DATA" | jq -r '.privateIpGoogleAccess')
        S_REGION=$(echo "$SUBNET_DATA" | jq -r '.region' | awk -F'/' '{print $NF}')
        [[ "$PGA" == "true" ]] && echo "  [PASS] Subnet: $SUBNET_NAME ($S_REGION) -> PGA: ENABLED" || echo "  [FAIL] Subnet: $SUBNET_NAME ($S_REGION) -> PGA: DISABLED"
    else
        echo "  [INFO] No subnet provided. Auditing all subnets in '$VPC_NAME'..."
        ALL_SUBNETS=$(gcloud compute networks subnets list --project="$PROJECT_ID" --filter="network~$VPC_NAME" --format="json")
        echo "$ALL_SUBNETS" | jq -c '.[]' | while read -r sub; do
            S_NAME=$(echo "$sub" | jq -r '.name')
            S_PGA=$(echo "$sub" | jq -r '.privateIpGoogleAccess')
            S_REG=$(echo "$sub" | jq -r '.region' | awk -F'/' '{print $NF}')
            [[ "$S_PGA" == "true" ]] && echo "  [PASS] Subnet: $S_NAME ($S_REG) -> PGA: ENABLED" || echo "  [WARN] Subnet: $S_NAME ($S_REG) -> PGA: DISABLED"
        done
    fi
    echo ""
}

# ---------------------------------------------------------
# Function: Firewall Ingress (GCP Service CIDRs)
# ---------------------------------------------------------
check_firewall_cidrs() {
    echo -e "\n[*] Probing Firewall Ingress for GCP Services..."
    echo "------------------------------------------------------------"
    declare -A REQUIRED_RANGES=( ["35.191.0.0/16"]="Health Checks" ["130.211.0.0/22"]="Health Checks" ["199.36.153.8/30"]="Private Google APIs" ["35.235.240.0/20"]="IAP (SSH/AD)" ["35.199.192.0/19"]="Cloud DNS" )
    CURRENT_INGRESS=$(gcloud compute firewall-rules list --project="$PROJECT_ID" --filter="network=$VPC_NAME AND direction=INGRESS" --format="value(sourceRanges.list())")

    for cidr in "${!REQUIRED_RANGES[@]}"; do
        echo "$CURRENT_INGRESS" | grep -q "$cidr" && echo "  [PASS] Found: $cidr" || echo "  [FAIL] Missing: $cidr (${REQUIRED_RANGES[$cidr]})"
    done
    echo ""
}

# ---------------------------------------------------------
# Function: Firewall Port Auditor
# ---------------------------------------------------------
check_fabric_ports() {
    echo -e "\n[*] Identifying Active Ingress Rules in $VPC_NAME for Port Audit..."
    echo "------------------------------------------------------------"

    if [[ -n "$TARGET_RULE" ]]; then
        RULES_JSON=$(gcloud compute firewall-rules describe "$TARGET_RULE" --project="$PROJECT_ID" --format="json" 2>/dev/null)
        [[ -z "$RULES_JSON" ]] && echo "[FAIL] Rule '$TARGET_RULE' not found." && exit 1
        RULES_JSON="[$RULES_JSON]"
    else
        ALL_INGRESS_RULES=$(gcloud compute firewall-rules list --project="$PROJECT_ID" \
            --filter="direction=INGRESS AND disabled=false" --format="json")
        
        RULES_JSON=$(echo "$ALL_INGRESS_RULES" | jq -c "[.[] | select(.network | contains(\"$VPC_NAME\")) | select(.allowed != null)]")
    fi

    # Visual Summary
    echo "$RULES_JSON" | jq -r '.[] | "  -> Found: \(.name) (Allow: \(.allowed[0].IPProtocol // "none"):\(.allowed[0].ports // ["all"] | join(",")))"'

    if [[ -z "$RULES_JSON" || "$RULES_JSON" == "[]" ]]; then
        echo -e "\n[ERROR] No active ingress rules detected. Audit stopped."
        exit 1
    fi

    check_port() {
        local proto=$1; local port=$2; local label=$3
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
    echo ""
}

# ---------------------------------------------------------
# Function: Identity & Permission Probe
# ---------------------------------------------------------
check_iam_permissions() {
    echo -e "\n[*] Probing Identity & Permissions..."
    echo "------------------------------------------------------------"
    CURRENT_AUTH=$(gcloud config get-value core/account 2>/dev/null)
    echo "    Identity: $CURRENT_AUTH"

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
    echo ""
}

# ---------------------------------------------------------
# Function: Z3 and Local SSD Quota Audit
# Will check all regions with Z3 quota and check CPU and SSD requirements,
# will check only the target subnet's region if provided.
# ---------------------------------------------------------
check_quotas() {
    echo -e "\n[*] Scanning Z3 and Local SSD Quotas (Global Intersection)..."
    echo "------------------------------------------------------------"
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
}

# ---------------------------------------------------------
# Function: Remediations
# ---------------------------------------------------------
show_remediations() {
    TARGET_LOC=${S_REGION:-"us-central1"}
    cat << EOF

============================================================
 QUOTA INCREASE TEMPLATE (Target: $TARGET_LOC)
============================================================
gcloud alpha quotas preferences create --project=$PROJECT_ID \\
  --service=compute.googleapis.com --metric=compute.googleapis.com/cpus_per_vm_family \\
  --dimensions=vm_family=Z3,location=$TARGET_LOC --preferred-value=1500

gcloud alpha quotas preferences create --project=$PROJECT_ID \\
  --service=compute.googleapis.com --metric=compute.googleapis.com/local_ssd_total_storage_per_vm_family \\
  --dimensions=vm_family=Z3,location=$TARGET_LOC --preferred-value=1000000

============================================================
 Validation Complete.
============================================================
EOF
}

# ---------------------------------------------------------
# Main Execution Flow
# ---------------------------------------------------------
main() {
    preflight_check
    check_apis
    check_infrastructure
    check_firewall_cidrs
    check_fabric_ports
    check_iam_permissions
    check_quotas
    show_remediations
}

# Run the master script
main