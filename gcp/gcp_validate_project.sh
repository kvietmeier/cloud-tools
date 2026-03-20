#!/bin/bash
# ==============================================================================
# VAST Data GCP Master Validator (Combined & Modular)
# Copyright 2026 VAST Data. Licensed under the Apache License, Version 2.0;
# you may not use this file except in compliance with the License.
# ==============================================================================
# SUMMARY:
# This tool performs a comprehensive "ready-to-build" audit for VAST clusters
# in Google Cloud. It validates APIs, network infrastructure (VPC, Subnets, PGA),
# GCP Service CIDR ingress, VAST protocol/fabric firewall rules, IAM permissions,
# and Z3 hardware quota availability.
#
# USAGE:
#   ./gcp_check_all.sh [PROJECT_ID] [VPC_NAME] [SUBNET_NAME] [TARGET_RULE] [-v]
# ==============================================================================

# ---------------------------------------------------------
# Global Setup & Argument Parsing
# ---------------------------------------------------------
for cmd in gcloud jq comm curl; do
    if ! command -v $cmd &> /dev/null; then
        echo "[FAIL] Missing dependency: $cmd"
        exit 1
    fi
done

VERBOSE=false
POSITIONAL_ARGS=()

for arg in "$@"; do
    if [[ "$arg" == "-v" || "$arg" == "--verbose" ]]; then
        VERBOSE=true
    else
        POSITIONAL_ARGS+=("$arg")
    fi
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
[[ -z "$SUBNET_NAME" ]] && read -p "Enter Target Subnet where Cluster will be Installed (Leave blank for ALL): " SUBNET_NAME
[[ -z "$TARGET_RULE" ]] && read -p "Firewall Rule Name to Check (Leave blank for FULL VPC SCAN): " TARGET_RULE

if [[ -z "$PROJECT_ID" ]]; then
    echo "[FAIL] No Project ID provided. Exiting."
    exit 1
fi

# ---------------------------------------------------------
# Optional File Logging Feature
# ---------------------------------------------------------
read -p "Would you like to save this audit output to a log file? (y/N): " SAVE_LOG
if [[ "$SAVE_LOG" =~ ^[Yy]$ ]]; then
    LOG_FILE="vast_gcp_audit_${PROJECT_ID}_$(date +%Y%m%d_%H%M%S).log"
    echo "Logging all output to $LOG_FILE..."
    # This pipes all terminal output to the log file without changing any echo commands
    exec > >(tee -i "$LOG_FILE")
    exec 2>&1
fi

echo -e "\n========================================================================"
echo " VAST on Cloud Requirements Validator Using Project: $PROJECT_ID"
echo " VPC: $VPC_NAME | Subnet: ${SUBNET_NAME:-ALL}"
echo " Rule: ${TARGET_RULE:-FULL VPC SCAN}"
[[ "$VERBOSE" == "true" ]] && echo " MODE: Verbose (Listing all permissions)"
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
# Function: VAST Protocol & Fabric Auditor
# ---------------------------------------------------------
check_fabric_ports() {
    echo -e "\n[*] Identifying Active Ingress Rules in $VPC_NAME for Fabric Audit..."
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

    echo -e "\n[*] PHASE 1: Client & Management Connectivity"
    echo "------------------------------------------------------------"
    for p in "2049:tcp:NFS" "445:tcp:SMB" "4420:tcp:NVMe-oF" "443:tcp:HTTPS/Mgmt" "80:tcp:HTTP" "22:tcp:SSH" "389:tcp:LDAP" "636:tcp:Secure LDAP" "3268:tcp:LDAP Cat" "3269:tcp:LDAP Cat SSL"; do
        IFS=":" read -r port proto lab <<< "$p"; check_port "$proto" "$port" "$lab"
    done

    echo -e "\n[*] PHASE 2: Internal Cluster Fabric (Node-to-Node)"
    echo "------------------------------------------------------------"
    echo "--- Control & Monitoring ---"
    for p in "5551:tcp:vms_monitor" "6000:tcp:Leader" "6001:tcp:Leader Alt" "8000:tcp:mcvms" "3128:tcp:Call Home Proxy" "5000:tcp:Docker Registry"; do
        IFS=":" read -r port proto lab <<< "$p"; check_port "$proto" "$port" "$lab"
    done

    echo -e "\n--- Data Plane & Internal RPC ---"
    for p in "4000:tcp:Dnode Internal" "4100:tcp:Dnode Internal" "4200:tcp:Cnode Internal" "4201:tcp:Cnode Internal" "5200:tcp:Cnode Internal Data" "5201:tcp:Cnode Internal Data" "4520:tcp:SPDK Target" "7000:tcp:Dnode Internal" "7100:tcp:Dnode Internal"; do
        IFS=":" read -r port proto lab <<< "$p"; check_port "$proto" "$port" "$lab"
    done

    echo -e "\n--- CAS & Silos (UDP/TCP) ---"
    for p in "4001:udp:Dnode Internal UDP" "4005:udp:Dnode1 Platform CAS" "4105:udp:Dnode1 Data CAS" "4205:udp:CAS Operations" "6005:udp:Leader CAS" "5205:udp:Cnode Silo Start" "5239:udp:Cnode Silo End"; do
        IFS=":" read -r port proto lab <<< "$p"; check_port "$proto" "$port" "$lab"
    done

    echo -e "\n--- Support & RPC Services ---"
    for p in "111:tcp:rpcbind" "20048:tcp:mount" "20106:tcp:NSM/Status" "20107:tcp:NLM/nlockmgr" "20108:tcp:NFS_RQUOTA" "9090:tcp:Tabular" "9092:tcp:Kafka"; do
        IFS=":" read -r port proto lab <<< "$p"; check_port "$proto" "$port" "$lab"
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

    declare -A PERM_GROUPS=(
        ["Cloud Functions"]="cloudfunctions.functions.create cloudfunctions.functions.delete cloudfunctions.functions.get cloudfunctions.functions.getIamPolicy cloudfunctions.functions.setIamPolicy cloudfunctions.operations.get"
        ["Compute Engine"]="compute.addresses.createInternal compute.addresses.deleteInternal compute.addresses.get compute.addresses.setLabels compute.addresses.useInternal compute.disks.create compute.disks.setLabels compute.healthChecks.create compute.healthChecks.delete compute.healthChecks.get compute.healthChecks.use compute.images.get compute.images.useReadOnly compute.instanceGroupManagers.create compute.instanceGroupManagers.delete compute.instanceGroupManagers.get compute.instanceGroups.create compute.instanceGroups.delete compute.instanceGroups.get compute.instanceTemplates.create compute.instanceTemplates.delete compute.instanceTemplates.get compute.instanceTemplates.useReadOnly compute.instances.create compute.instances.get compute.instances.setLabels compute.instances.setMetadata compute.instances.setTags compute.regionOperations.get compute.subnetworks.get compute.subnetworks.use compute.resourcePolicies.create compute.resourcePolicies.delete compute.resourcePolicies.get"
        ["IAM & SAs"]="iam.roles.create iam.roles.delete iam.roles.get iam.roles.undelete iam.serviceAccounts.actAs iam.serviceAccounts.create iam.serviceAccounts.delete iam.serviceAccounts.get"
        ["Resource Manager"]="resourcemanager.projects.get resourcemanager.projects.getIamPolicy resourcemanager.projects.setIamPolicy"
        ["Secret Manager"]="secretmanager.secrets.create secretmanager.secrets.delete secretmanager.secrets.get secretmanager.versions.access secretmanager.versions.add secretmanager.versions.destroy secretmanager.versions.enable secretmanager.versions.get"
        ["Cloud Storage"]="storage.buckets.create storage.buckets.delete storage.buckets.get storage.objects.create storage.objects.delete storage.objects.get"
    )

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
    echo ""
}

# ---------------------------------------------------------
# Function: Z3 Quota Audit
# ---------------------------------------------------------
check_quotas() {
    echo -e "\n[*] Scanning Z3 Quotas (Global Intersection)..."
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