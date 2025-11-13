#!/bin/bash
#====================================================================
# GCP VPN/BGP Tunnel Diagnostic (Final Dynamic Version)
#====================================================================

# --- VARIABLES ---
REGION="us-central1"
VPC="karlv-corevpc"
VPN_GATEWAY="vpn-gateway-azure-central1"
ROUTER="router-azure-central1"
FIREWALL_RULE="allow-new-azure-ipsec"

# --- DISPLAY HELPERS ---
echo "=============================="
echo "GCP VPN/BGP Status Diagnostic"
echo "=============================="

#-------------------------------
# VPN TUNNEL STATUS
#-------------------------------
echo ""
echo "VPN Tunnel Status (${VPN_GATEWAY})"
echo "---------------------------------------"

# Capture tunnel list output (essential for dynamic diagnosis)
TUNNEL_STATUS_OUTPUT=$(gcloud compute vpn-tunnels list \
    --filter="vpnGateway=$VPN_GATEWAY" \
    --format="table(name,peerIp,status,detailedStatus)" 2>/dev/null)

echo "$TUNNEL_STATUS_OUTPUT" || echo "!! Error listing tunnels. Check VPN_GATEWAY name."

#-------------------------------
# FIREWALL CHECK
#-------------------------------
echo ""
echo "Checking Critical VPN Ingress Firewall Rule (${FIREWALL_RULE})..."
echo "------------------------------------------------------------------"

gcloud compute firewall-rules describe $FIREWALL_RULE 2>/dev/null | 
    grep -E 'name:|direction:|priority:|sourceRanges:|allowed:' || echo "!! CRITICAL: Rule ${FIREWALL_RULE} not found or inaccessible."

#-------------------------------
# ROUTER STATUS / BGP PEER
#-------------------------------
echo ""
echo "Cloud Router & BGP Peer Status (${ROUTER})"
echo "---------------------------------------------"
ROUTER_STATUS_JSON=$(gcloud compute routers get-status $ROUTER --region=$REGION --format="json" 2>/dev/null)

if [[ -z "$ROUTER_STATUS_JSON" ]]; then
    echo "!! No router status available. Router may not exist or be provisioning."
else
    # Output BGP Peer status
    echo "$ROUTER_STATUS_JSON" | jq -r '
        .result.bgpPeerStatus[]? |
        "Peer: \(.name) | Status: \(.status) | Uptime: \(.uptime) | Learned Routes: \(.numLearnedRoutes)"'
fi

#-------------------------------
# LEARNED ROUTES
#-----------------------------------
echo ""
echo "📡 Learned Routes (from BGP Peers)"
echo "-----------------------------------"
if [[ -n "$ROUTER_STATUS_JSON" ]]; then
    # Capture the output, which will be empty if no routes are learned
    ROUTES=$(echo "$ROUTER_STATUS_JSON" | jq -r '
        .result.bestRoutes[]? |
        select(.routeType=="BGP") |
        "\(.destRange) -> NextHop: \(.nextHopIp)"' 2>/dev/null)
    
    if [[ -n "$ROUTES" ]]; then
        echo "$ROUTES"
    else
        echo "(No BGP routes learned yet.)"
    fi
else
    echo "(No router status available to check routes.)"
fi

#-------------------------------
# ROUTER INTERFACES
#---------------------
echo ""
echo "Router Interfaces (IPs and Tunnel Links)"
echo "----------------------------------------"

# Use the reliable 'describe' command output to list interfaces and links
gcloud compute routers describe $ROUTER --region $REGION --format="json" 2>/dev/null | jq -r '
    .interfaces[]? |
    "Interface: \(.name) | IP Range: \(.ipRange) | Linked Tunnel: \(.linkedVpnTunnel)"' || echo "!! Error retrieving router interfaces."

#==============================================================
# DYNAMIC FAILURE DIAGNOSIS (The new dynamic logic)
#==============================================================
echo ""
echo "=============================="
echo "FINAL DYNAMIC FAILURE ANALYSIS"
echo "=============================="

# Check if both tunnels are stuck in the NO_INCOMING_PACKETS state
if echo "$TUNNEL_STATUS_OUTPUT" | grep -q "NO_INCOMING_PACKETS"; then
    echo "ROOT CAUSE: IPSEC FAILURE (Phase 1 Block)"
    echo "Diagnosis: The GCP VPN Gateway is unable to complete the initial handshake because no response"
    echo "is being received from the Azure Public IP addresses. Since your GCP firewall is open,"
    echo "the block is external."
    echo ""
    echo "ACTION REQUIRED: AZURE PEER"
    echo "1. Verify the Pre-Shared Key (PSK) is an exact match on the Azure Connection object."
    echo "2. Check Azure NSG/Firewall rules on the GatewaySubnet to ensure inbound traffic is allowed"
    echo "   from your two GCP Public IPs (UDP 500, UDP 4500, and Protocol ESP)."

elif echo "$ROUTER_STATUS_JSON" | grep -q "ESTABLISHED" && echo "$ROUTER_STATUS_JSON" | jq '.result.bgpPeerStatus[]? | select(.status=="DOWN")' -r | grep -q 'DOWN'; then
    echo "ROOT CAUSE: PARTIAL BGP FAILURE"
    echo "Diagnosis: At least one IPsec tunnel is up (ESTABLISHED), but BGP is failing to negotiate on one or both paths."
    echo "The issue is likely an IP/ASN mismatch in the Azure Local Network Gateway (LNG) BGP settings."
    echo ""
    echo "ACTION REQUIRED: AZURE PEER"
    echo "1. Verify the Azure Local Network Gateway BGP Peer IPs are correctly set to your GCP BGP IPs (169.254.21.10 and 169.254.21.14)."

elif echo "$TUNNEL_STATUS_OUTPUT" | grep -q "ESTABLISHED" && echo "$ROUTER_STATUS_JSON" | jq -r '.result.bgpPeerStatus[]? | select(.status=="ESTABLISHED")' | wc -l | grep -q 2; then
    echo "ROOT CAUSE: CONNECTION SUCCESSFUL"
    echo "Status: Both tunnels are ESTABLISHED, and BGP sessions are up. Routes should be exchanged."
    echo "Verification: Check the 'Learned Routes' section above for Azure CIDRs."

else
    echo "STATUS: UNKNOWN OR PROVISIONING"
    echo "Diagnosis: The configuration is still settling. Wait 5-10 minutes and check again."
fi
