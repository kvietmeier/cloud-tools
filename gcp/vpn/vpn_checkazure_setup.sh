#!/bin/bash
#====================================================================
# GCP VPN/BGP Tunnel Diagnostic (Modular Functions Version - FINAL)
#====================================================================
#!/bin/bash
#
# Copyright 2025 Karlv
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This file is an open-source contribution and is provided as-is.
#

# --- SCRIPT SUMMARY AND EXPLANATION ---
# 
# Purpose: Diagnose HA VPN (BGP) connectivity issues between Google Cloud and a Peer VPN Gateway (e.g., Azure).
# 
# Explanation: This script sequentially checks the three critical layers of a BGP-based VPN connection:
# 1. IPsec Tunnel Status (Layer 3 Tunneling): Confirms Phase 1/2 negotiation success.
# 2. VPC Firewall Rules: Confirms inbound allowance for BGP (TCP 179) and IPsec traffic.
# 3. Cloud Router Status (Layer 4/5 BGP Peering): Checks the BGP Finite State Machine (sessionState)
#    and the learned routes table.
# 
# The script provides a final root cause analysis based on the observed statuses:
# - If tunnels fail: The problem is external firewall/PSK mismatch.
# - If tunnels are UP but BGP is DOWN: The problem is an IP/ASN/MD5 mismatch on the Azure peer configuration.
# - If both are UP: Success.
#
#====================================================================


# --- GLOBAL VARIABLES ---
#
REGION="us-central1"
VPC="karlv-corevpc"
VPN_GATEWAY="vpn-gateway-azure-central1"
ROUTER="router-azure-central1"
FIREWALL_RULE="allow-new-azure-ipsec"

# --- GLOBAL STORAGE ---
ROUTER_STATUS_JSON=""
TUNNEL_STATUS_OUTPUT=""
TUNNEL_ESTABLISHED_COUNT=0
BGP_ESTABLISHED_COUNT=0

# --------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------

function display_header() {
    echo "================================================================================"
    echo "  GCP VPN/BGP Status Diagnostic"
    echo "================================================================================"
}

function check_vpn_tunnels() {
    echo ""
    echo "VPN Tunnel Status (${VPN_GATEWAY})"
    echo "---------------------------------------"
    
    TUNNEL_STATUS_OUTPUT=$(gcloud compute vpn-tunnels list \
        --filter="vpnGateway=$VPN_GATEWAY" \
        --format="table(name,peerIp,status,detailedStatus)" 2>/dev/null)
    
    echo "$TUNNEL_STATUS_OUTPUT" || echo "!! Error listing tunnels. Check VPN_GATEWAY name."

    # Set global tunnel status count
    TUNNEL_ESTABLISHED_COUNT=$(echo "$TUNNEL_STATUS_OUTPUT" | grep -c "ESTABLISHED")
}

function check_firewall() {
    echo ""
    echo "Checking Critical VPN Ingress Firewall Rule (${FIREWALL_RULE})..."
    echo "------------------------------------------------------------------"
    
    gcloud compute firewall-rules describe $FIREWALL_RULE 2>/dev/null | 
        grep -E 'name:|direction:|priority:|sourceRanges:|allowed:' || echo "!! CRITICAL: Rule ${FIREWALL_RULE} not found or inaccessible."
}

function check_router_and_bgp() {
    echo ""
    echo "Cloud Router & BGP Peer Status (${ROUTER})"
    echo "---------------------------------------------"
    ROUTER_STATUS_JSON=$(gcloud compute routers get-status $ROUTER --region=$REGION --format="json" 2>/dev/null)

    if [[ -z "$ROUTER_STATUS_JSON" ]]; then
        echo "!! No router status available. Router may not exist or be provisioning."
    else
        # Output detailed BGP Peer status including sessionState (link status)
        echo "$ROUTER_STATUS_JSON" | jq -r '
            .result.bgpPeerStatus[]? |
            "Peer: \(.name) (\(.peerIpAddress)) | State: \(.sessionState) | Uptime: \(.uptime) | Learned Routes: \(.numLearnedRoutes)"'

        # Set global BGP status count
        BGP_ESTABLISHED_COUNT=$(echo "$ROUTER_STATUS_JSON" | jq -r '.result.bgpPeerStatus[]? | select(.sessionState=="ESTABLISHED")' | wc -l)
    fi
}

function check_learned_routes() {
    echo ""
    echo "📡 Learned Routes (from BGP Peers)"
    echo "-----------------------------------"
    if [[ -n "$ROUTER_STATUS_JSON" ]]; then
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
}

function check_router_interfaces() {
    echo ""
    echo "Router Interfaces (IPs and Tunnel Links)"
    echo "----------------------------------------"

    gcloud compute routers describe $ROUTER --region $REGION --format="json" 2>/dev/null | jq -r '
        .interfaces[]? |
        "Interface: \(.name) | IP Range: \(.ipRange) | Linked Tunnel: \(.linkedVpnTunnel)"' || echo "!! Error retrieving router interfaces."
}

function dynamic_failure_analysis() {
    echo ""
    echo "=============================="
    echo "FINAL DYNAMIC FAILURE ANALYSIS"
    echo "=============================="

    # 1. Successful Connection (Both tunnels and both BGP peers UP)
    if [[ $TUNNEL_ESTABLISHED_COUNT -ge 2 ]] && [[ $BGP_ESTABLISHED_COUNT -ge 2 ]]; then
        echo "ROOT CAUSE: CONNECTION SUCCESSFUL"
        echo "Status: Both tunnels are ESTABLISHED, and BGP sessions are UP."
        echo "Verification: Check the 'Learned Routes' section above for Azure CIDRs."

    # 2. BGP Peering Failure (Tunnels UP, BGP DOWN)
    # Checks if tunnels are ESTABLISHED AND if at least one BGP peer is NOT ESTABLISHED.
    elif [[ $TUNNEL_ESTABLISHED_COUNT -ge 2 ]] && [[ $BGP_ESTABLISHED_COUNT -lt 2 ]]; then
        
        NON_EST_STATE=$(echo "$ROUTER_STATUS_JSON" | jq -r '.result.bgpPeerStatus[]? | select(.sessionState!="ESTABLISHED") | .sessionState' | head -n 1)

        echo "ROOT CAUSE: BGP PEERING FAILURE"
        echo "Status: IPsec Tunnels are UP, but BGP session(s) are stuck in state: ${NON_EST_STATE}"
        echo "Diagnosis: Check BGP settings (IPs, ASNs, PSK) on the Azure peer gateway."

    # 3. IPsec failure (Phase 1 Block)
    elif echo "$TUNNEL_STATUS_OUTPUT" | grep -q "NO_INCOMING_PACKETS"; then
        echo "ROOT CAUSE: IPSEC FAILURE (Phase 1 Block)"
        echo "Diagnosis: The block is external. Check Azure NSG/Firewall rules for GCP Public IPs (UDP 500/4500, ESP)."

    # 4. Unknown/Settling (The fallback)
    else
        echo "STATUS: UNKNOWN OR PROVISIONING"
        echo "Diagnosis: The configuration is still settling. Wait 5-10 minutes and check again."
    fi
}

# --------------------------------------------------------------------
# MAIN EXECUTION
# --------------------------------------------------------------------

display_header
check_vpn_tunnels
check_firewall
check_router_and_bgp
check_learned_routes
check_router_interfaces
dynamic_failure_analysis