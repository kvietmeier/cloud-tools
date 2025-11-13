#!/bin/bash
# GCP-Azure HA VPN Connection Management Script
# This script creates and tears down the required GCP resources for an HA VPN connection to Azure.

set -euo pipefail # Exit immediately if a command exits with a non-zero status.

echo "Loading configuration variables..."

### VPC and Region
PROJECT="clouddev-itdesk124"
GCP_REGION="us-central1"
GCP_VPC="karlv-corevpc"

### VPN Gateway, Router, External GW, and BGP ASN
HA_VPN_GW_NAME="vpn-gateway-azure-central1"
ROUTER_NAME="router-azure-central1"
EXTERNAL_GW_NAME="vpngw-azure"
GCP_ASN="65333"
TUNNEL_IF0="vpn-tunnel-azure-central1-if0"
TUNNEL_IF1="vpn-tunnel-azure-central1-if1"
INTERFACE0="azure-tunnel-if0"
INTERFACE1="azure-tunnel-if1"
BGP_PEER_IF0="azure-bgp-peer-if0"
BGP_PEER_IF1="azure-bgp-peer-if1"
PRIORITY=100

### From Azure -
NEW_KEY='Q()dPJmvMHxca0(!n$Gc'
AZURE_PUBIP0="20.121.130.26"
AZURE_PUBIP1="172.172.233.46"
AZURE_APIPA_BGP_A="169.254.21.2"  # Azure's BGP IP
AZURE_APIPA_BGP_B="169.254.22.2"  # Azure's BGP IP
AZURE_ASN_B="65006"


function build() {
    echo "--- Starting HA VPN Build Process in GCP ---"

    # 1. Create the HA VPN Gateway
    echo "1. Creating HA VPN Gateway: $HA_VPN_GW_NAME"
    gcloud compute vpn-gateways create \
        "$HA_VPN_GW_NAME" \
        --network "$GCP_VPC" \
        --region "$GCP_REGION"

    # 2. Create the Cloud Router
    echo "2. Creating Cloud Router: $ROUTER_NAME with ASN $GCP_ASN"
    gcloud compute routers create \
        "$ROUTER_NAME" \
        --network "$GCP_VPC" \
        --region "$GCP_REGION" \
        --asn "$GCP_ASN"

    # 3. Create the External VPN Gateway (Azure Side)
    echo "3. Creating External VPN Gateway: $EXTERNAL_GW_NAME with IPs $AZURE_PUBIP0 and $AZURE_PUBIP1"
    gcloud compute external-vpn-gateways create \
        "$EXTERNAL_GW_NAME" \
        --interfaces 0="$AZURE_PUBIP0",1="$AZURE_PUBIP1"

    # 4. Create VPN Tunnels
    echo "4. Creating VPN Tunnel 0: $TUNNEL_IF0"
    gcloud compute vpn-tunnels create "$TUNNEL_IF0" \
        --peer-external-gateway="$EXTERNAL_GW_NAME" \
        --peer-external-gateway-interface=0 \
        --region="$GCP_REGION" \
        --ike-version=2 \
        --shared-secret="$NEW_KEY" \
        --router="$ROUTER_NAME" \
        --vpn-gateway="$HA_VPN_GW_NAME" \
        --interface=0

    echo "5. Creating VPN Tunnel 1: $TUNNEL_IF1"
    gcloud compute vpn-tunnels create "$TUNNEL_IF1" \
        --peer-external-gateway="$EXTERNAL_GW_NAME" \
        --peer-external-gateway-interface=1 \
        --region="$GCP_REGION" \
        --ike-version=2 \
        --shared-secret="$NEW_KEY" \
        --router="$ROUTER_NAME" \
        --vpn-gateway="$HA_VPN_GW_NAME" \
        --interface=1

    # 5. Add Router Interfaces (connects tunnels to router)
    echo "6. Adding Router Interface 0: $INTERFACE0"
    gcloud compute routers add-interface "$ROUTER_NAME" \
        --interface-name="$INTERFACE0" \
        --vpn-tunnel="$TUNNEL_IF0" \
        --region="$GCP_REGION"

    echo "7. Adding Router Interface 1: $INTERFACE1"
    gcloud compute routers add-interface "$ROUTER_NAME" \
        --interface-name="$INTERFACE1" \
        --vpn-tunnel="$TUNNEL_IF1" \
        --region="$GCP_REGION"

    # 6. Add BGP Peers
    echo "8. Adding BGP Peer 0: $BGP_PEER_IF0 (to Azure IP $AZURE_APIPA_BGP_A)"
    gcloud compute routers add-bgp-peer "$ROUTER_NAME" \
        --peer-name="$BGP_PEER_IF0" \
        --peer-asn="$AZURE_ASN_B" \
        --interface="$INTERFACE0" \
        --peer-ip-address="$AZURE_APIPA_BGP_A" \
        --region="$GCP_REGION" \
        --advertised-route-priority="$PRIORITY"

    echo "9. Adding BGP Peer 1: $BGP_PEER_IF1 (to Azure IP $AZURE_APIPA_BGP_B)"
    gcloud compute routers add-bgp-peer "$ROUTER_NAME" \
        --peer-name="$BGP_PEER_IF1" \
        --peer-asn="$AZURE_ASN_B" \
        --interface="$INTERFACE1" \
        --peer-ip-address="$AZURE_APIPA_BGP_B" \
        --region="$GCP_REGION" \
        --advertised-route-priority="$PRIORITY"

    echo "--- HA VPN Build Complete! Tunnels should now establish. ---"
}


function remove() {
    echo "--- Starting HA VPN Removal Process in GCP ---"

    # 1. Remove BGP Peers (must be done before deleting interfaces/router)
    echo "1. Removing BGP Peer 0: $BGP_PEER_IF0"
    gcloud compute routers remove-bgp-peer "$ROUTER_NAME" \
        --project="$PROJECT" \
        --region="$GCP_REGION" \
        --peer-name="$BGP_PEER_IF0" --quiet

    echo "2. Removing BGP Peer 1: $BGP_PEER_IF1"
    gcloud compute routers remove-bgp-peer "$ROUTER_NAME" \
        --project="$PROJECT" \
        --region="$GCP_REGION" \
        --peer-name="$BGP_PEER_IF1" --quiet
    
    # 2. Remove Router Interfaces (must be done before deleting the router)
    echo "3. Removing Router Interface 0: $INTERFACE0"
    gcloud compute routers remove-interface "$ROUTER_NAME" \
        --interface-name="$INTERFACE0" \
        --region="$GCP_REGION" --quiet
    
    echo "4. Removing Router Interface 1: $INTERFACE1"
    gcloud compute routers remove-interface "$ROUTER_NAME" \
        --interface-name="$INTERFACE1" \
        --region="$GCP_REGION" --quiet

    # 3. Delete VPN Tunnels (must be done before deleting the gateway and router)
    echo "5. Deleting VPN Tunnel 0: $TUNNEL_IF0"
    gcloud compute vpn-tunnels delete "$TUNNEL_IF0" --region="$GCP_REGION" --quiet
    
    echo "6. Deleting VPN Tunnel 1: $TUNNEL_IF1"
    gcloud compute vpn-tunnels delete "$TUNNEL_IF1" --region="$GCP_REGION" --quiet

    # 4. Delete Gateways and Router
    echo "7. Deleting Cloud Router: $ROUTER_NAME"
    gcloud compute routers delete "$ROUTER_NAME" --region="$GCP_REGION" --quiet

    echo "8. Deleting HA VPN Gateway: $HA_VPN_GW_NAME"
    gcloud compute vpn-gateways delete "$HA_VPN_GW_NAME" --region="$GCP_REGION" --quiet
    
    echo "9. Deleting External VPN Gateway: $EXTERNAL_GW_NAME"
    gcloud compute external-vpn-gateways delete "$EXTERNAL_GW_NAME" --region="$GCP_REGION" --quiet

    echo "--- HA VPN Removal Complete! All related GCP resources have been deleted. ---"
}

# Check for function arguments
if [ $# -eq 0 ]; then
    echo "Usage: $0 {build|remove}"
    exit 1
fi

# Execute the requested function
if [ "$1" == "build" ]; then
    build
elif [ "$1" == "remove" ]; then
    remove
else
    echo "Invalid command. Use 'build' or 'remove'."
    exit 1
fi