#!/bin/bash

# Default Values
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
VPC_NAME="default"
REGION="us-central1"

# Parse command line flags for easier input
while getopts "p:v:r:h" opt; do
  case $opt in
    p) PROJECT_ID="$OPTARG" ;;
    v) VPC_NAME="$OPTARG" ;;
    r) REGION="$OPTARG" ;;
    h) echo "Usage: $0 [-p project_id] [-v vpc_name] [-r region]"; exit 0 ;;
    *) echo "Usage: $0 [-p project_id] [-v vpc_name] [-r region]"; exit 1 ;;
  esac
done

# Thresholds
MIN_Z3_CPU=1500
MIN_SSD_GB=1000000 # 1,000 TB

echo "---------------------------------------------------------"
echo " Checking Project: $PROJECT_ID for VAST Polaris Readiness"
echo " VPC: $VPC_NAME | Region: $REGION"
echo "---------------------------------------------------------"

# Helper function to catch command errors gracefully
check_resource() {
    local cmd="$1"
    local output
    output=$(eval "$cmd" 2>&1)
    if [ $? -ne 0 ]; then echo "CMD_ERROR"; return 1; fi
    echo "$output"
}

# ---------------------------------------------------------
# 1. API Check
# ---------------------------------------------------------
echo -e "\n[1/5] Checking Enabled APIs..."
REQUIRED_APIS=("compute.googleapis.com" "cloudfunctions.googleapis.com" "cloudbuild.googleapis.com" "secretmanager.googleapis.com" "servicenetworking.googleapis.com" "networkmanagement.googleapis.com" "artifactregistry.googleapis.com" "logging.googleapis.com" "monitoring.googleapis.com")

ENABLED_APIS=$(gcloud services list --project="$PROJECT_ID" --format="value(config.name)")

for api in "${REQUIRED_APIS[@]}"; do
    if echo "$ENABLED_APIS" | grep -q "$api"; then
        echo "  ✅ $api is enabled."
    else
        echo "  ❌ $api is NOT enabled."
    fi
done

# ---------------------------------------------------------
# 2. Quota Check (Z3 & Local SSD)
# ---------------------------------------------------------
echo -e "\n[2/5] Checking Performance Quotas..."
Q_JSON=$(check_resource "gcloud compute regions describe $REGION --project=$PROJECT_ID --format='json(quotas)'")

if [[ "$Q_JSON" == "CMD_ERROR" ]]; then
    echo "  ⚠️  Could not retrieve quotas (Check permissions)."
else
    # Parse Z3 limits. Also checks newer CPUS_PER_VM_FAMILY just in case.
    Z3_LIMIT=$(echo "$Q_JSON" | jq -r '.quotas[] | select(.metric == "Z3_CPUS") | .limit' 2>/dev/null)
    Z3_LIMIT=${Z3_LIMIT:-0}
    [[ "$Z3_LIMIT" == "null" || "$Z3_LIMIT" == "0" ]] && Z3_LIMIT=$(echo "$Q_JSON" | jq -r '.quotas[] | select(.metric == "CPUS_PER_VM_FAMILY") | .limit' 2>/dev/null)
    Z3_LIMIT=${Z3_LIMIT:-0}
    [[ "$Z3_LIMIT" == "null" ]] && Z3_LIMIT=0

    SSD_LIMIT=$(echo "$Q_JSON" | jq -r '.quotas[] | select(.metric == "LOCAL_SSD_TOTAL_GB") | .limit' 2>/dev/null)
    SSD_LIMIT=${SSD_LIMIT:-0}
    [[ "$SSD_LIMIT" == "null" ]] && SSD_LIMIT=0

    # Evaluate Z3 safely using awk 
    Z3_PASS=$(awk -v val="$Z3_LIMIT" -v min="$MIN_Z3_CPU" 'BEGIN {if (val >= min) print 1; else print 0}')
    if [ "$Z3_PASS" -eq 1 ]; then
        echo "  ✅ Z3_CPUS (or CPUS_PER_VM_FAMILY): $Z3_LIMIT (Pass: Limit is >= $MIN_Z3_CPU)"
    else
        echo "  ❌ Z3_CPUS (or CPUS_PER_VM_FAMILY): $Z3_LIMIT (Fail: Project needs at least $MIN_Z3_CPU)"
    fi

    # Evaluate Local SSD safely 
    SSD_PASS=$(awk -v val="$SSD_LIMIT" -v min="$MIN_SSD_GB" 'BEGIN {if (val >= min) print 1; else print 0}')
    if [ "$SSD_PASS" -eq 1 ]; then
        echo "  ✅ LOCAL_SSD: $SSD_LIMIT GB (Pass: Limit is >= 1,000,000 GB)"
    else
        echo "  ❌ LOCAL_SSD: $SSD_LIMIT GB (Fail: Project needs at least 1,000,000 GB)"
    fi
fi

# ---------------------------------------------------------
# 3. Network & Exhaustive Firewall Port Audit
# ---------------------------------------------------------
echo -e "\n[3/5] Auditing Exhaustive VAST Port List..."

# Check Private Service Access
PSA_CHECK=$(gcloud compute addresses list --global --filter="purpose=VPC_PEERING" --project="$PROJECT_ID" --format="value(name)" 2>/dev/null)
if [ -n "$PSA_CHECK" ]; then
    echo "  ✅ Found Private Service Access range: $PSA_CHECK"
else
    echo "  ❌ No Private Service Access (VPC Peering) range allocated."
fi

# Dump all ingress rules for the VPC to a temporary JSON file
gcloud compute firewall-rules list --project="$PROJECT_ID" --filter="network~.*/$VPC_NAME$ AND direction:INGRESS" --format="json(name,allowed)" > /tmp/vast_fw_rules.json 2>/dev/null

if [ ! -s /tmp/vast_fw_rules.json ]; then
    echo "  ⚠️  Could not retrieve firewall rules for VPC '$VPC_NAME' (Check permissions or VPC name)."
else
    echo "  🔍 Mathematically evaluating all 80+ VAST required TCP/UDP ports against your VPC rules..."
    
    PYTHON_OUT=$(python3 -c '
import json, sys

try:
    with open("/tmp/vast_fw_rules.json") as f:
        rules = json.load(f)
except Exception:
    print("JSON_ERROR")
    sys.exit(1)

# All Required Ports from VAST Documentation
req_tcp = set([22, 80, 111, 389, 443, 445, 636, 2049, 3268, 3269, 4420, 4520, 5000, 6126, 9090, 9092, 20048, 20106, 20107, 20108, 1611, 1612, 2611, 6000, 6001, 3128, 4000, 4001, 4100, 4101, 4200, 4201, 5200, 5201, 5551, 7000, 7100, 7101, 8000, 49001, 49002])
req_udp = set([4001, 4005, 4101, 4105, 4205, 6005, 7005, 7105]) | set(range(5205, 5240))

missing_tcp = req_tcp.copy()
missing_udp = req_udp.copy()

for rule in rules:
    for allow in rule.get("allowed", []):
        proto = allow.get("IPProtocol", "").lower()
        ports = allow.get("ports", [])
        
        if proto == "all":
            missing_tcp.clear()
            missing_udp.clear()
            break
            
        if proto == "tcp" and not ports:
            missing_tcp.clear()
        elif proto == "udp" and not ports:
            missing_udp.clear()
            
        for p in ports:
            if "-" in p:
                start, end = map(int, p.split("-"))
                prange = set(range(start, end + 1))
            else:
                prange = {int(p)}
            
            if proto == "tcp":
                missing_tcp -= prange
            elif proto == "udp":
                missing_udp -= prange

if not missing_tcp and not missing_udp:
    print("PASS")
else:
    if missing_tcp: print("FAIL_TCP: " + ", ".join(map(str, sorted(list(missing_tcp)))))
    if missing_udp: print("FAIL_UDP: " + ", ".join(map(str, sorted(list(missing_udp)))))
')

    if [[ "$PYTHON_OUT" == *"JSON_ERROR"* ]]; then
        echo "  ⚠️  Failed to parse firewall rules JSON."
    elif [[ "$PYTHON_OUT" == *"PASS"* ]]; then
        echo "  ✨ All required TCP and UDP ports are successfully allowed!"
    else
        echo "  ❌ Firewall rules are missing the following required VAST ports:"
        if echo "$PYTHON_OUT" | grep -q "FAIL_TCP"; then
            echo "     Blocked TCP: $(echo "$PYTHON_OUT" | grep "FAIL_TCP" | cut -d':' -f2 | sed 's/^ //')"
        fi
        if echo "$PYTHON_OUT" | grep -q "FAIL_UDP"; then
            echo "     Blocked UDP: $(echo "$PYTHON_OUT" | grep "FAIL_UDP" | cut -d':' -f2 | sed 's/^ //')"
        fi
    fi
fi
rm -f /tmp/vast_fw_rules.json

# ---------------------------------------------------------
# 4. GCP Infrastructure CIDR Ingress Check
# ---------------------------------------------------------
echo -e "\n[4/5] Auditing GCP Infrastructure CIDR Ingress..."

# Associative array to map CIDRs to their descriptions
declare -A CIDR_DESC=(
    ["35.191.0.0/16"]="Health Checks"
    ["130.211.0.0/22"]="Health Checks"
    ["199.36.153.8/30"]="Private Google APIs"
    ["35.235.240.0/20"]="IAP (Active Directory/SSH)"
    ["35.199.192.0/19"]="Cloud DNS"
)

for range in "${!CIDR_DESC[@]}"; do
    desc="${CIDR_DESC[$range]}"
    
    # We query GCP to see if ANY rule on this VPC allows traffic from this specific source range
    MATCH=$(check_resource "gcloud compute firewall-rules list --project=$PROJECT_ID --filter='network~.*/$VPC_NAME$ AND sourceRanges:$range AND direction:INGRESS' --format='value(name)'")
    
    if [[ "$MATCH" == "CMD_ERROR" ]]; then
        echo "  ⚠️  Cannot verify range $range"
    elif [ -n "$MATCH" ]; then
        # Clean up the output in case multiple rules allow it
        CLEAN_MATCH=$(echo "$MATCH" | tr '\n' ' ' | xargs)
        echo "  ✅ $range ($desc) allowed by rule(s): $CLEAN_MATCH"
    else
        echo "  ❌ $range ($desc) is NOT explicitly allowed."
    fi
done

# ---------------------------------------------------------
# 5. IAM Check
# ---------------------------------------------------------
echo -e "\n[5/5] Checking IAM Roles..."
CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --format="table(bindings.role)" \
    --filter="bindings.members:$CURRENT_ACCOUNT" 2>/dev/null)

if echo "$ROLES" | grep -E -q "roles/owner|roles/editor"; then
    echo "  ✅ Current account ($CURRENT_ACCOUNT) has administrative permissions."
else
    echo "  ⚠️  Current account ($CURRENT_ACCOUNT) may lack top-level permissions."
fi

echo -e "\n---------------------------------------------------------"
echo "Check complete. Review '❌' or '⚠️' items before deploying."