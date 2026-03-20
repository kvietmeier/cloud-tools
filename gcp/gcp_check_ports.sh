#!/bin/bash
# ==============================================================================
# VAST Data GCP Firewall Specialist (v4 - JSON Guard)
# ==============================================================================

PROJECT_ID=$1; VPC_NAME=$2; TARGET_RULE=$3
[[ -z "$PROJECT_ID" ]] && read -p "Project ID: " PROJECT_ID
[[ -z "$VPC_NAME" ]] && read -p "VPC Name: " VPC_NAME
[[ -z "$TARGET_RULE" ]] && read -p "Rule Name (Blank for SCAN ALL): " TARGET_RULE

echo "============================================================"
echo " VAST Protocol & Fabric Auditor: $PROJECT_ID"
echo " VPC: $VPC_NAME | Mode: ${TARGET_RULE:-FULL VPC SCAN}"
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

# ---------------------------------------------------------
# AUDIT START
# ---------------------------------------------------------
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

echo -e "\n============================================================"
echo " Audit Complete."
echo "============================================================"
