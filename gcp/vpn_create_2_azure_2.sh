# --- Configuration Variables ---
PROJECT="clouddev-itdesk124"
GCP_REGION="us-central1"
GCP_VPC="karlv-corevpc"
HA_VPN_GW_NAME="vpn-gateway-azure-central1"
ROUTER_NAME="router-azure-central1"
EXTERNAL_GW_NAME="vpn-gateway-azure-central1"
GCP_ASN="65333"
TUNNEL_IF0="vpn-tunnel-azure-central1-if0"
TUNNEL_IF1="vpn-tunnel-azure-central1-if1"
INTERFACE0="azure-tunnel-if0"
INTERFACE1="azure-tunnel-if1"
GCP_APIPA_BGP_A="169.254.21.9"
GCP_APIPA_BGP_B="169.254.22.9"
BGP_PEER_IF0="azure-bgp-peer-if0"
BGP_PEER_IF1="azure-bgp-peer-if1"
PRIORITY=100
SHARED_KEY='xVTsD61QPvDUPgD3bJvyaxo6s+peCTD6'
AZURE_PUBIP0="4.249.107.59"
AZURE_PUBIP1="4.249.107.48"
AZURE_APIPA_BGP_A="169.254.21.10"
AZURE_APIPA_BGP_B="169.254.22.10"
AZURE_ASN_B="65010"

# Generate a new key
openssl rand -base64 24
xVTsD61QPvDUPgD3bJvyaxo6s+peCTD6




# =========================================================================
# --- COMMANDS TO BUILD THE HA VPN CONNECTION ---
# These must be executed in order.
# =========================================================================

# 1. Create the HA VPN Gateway
gcloud compute vpn-gateways create "$HA_VPN_GW_NAME" --network "$GCP_VPC" --region "$GCP_REGION"

# 2. Create the Cloud Router
gcloud compute routers create "$ROUTER_NAME" --network "$GCP_VPC" --region "$GCP_REGION" --asn "$GCP_ASN"

# 3. Create the External VPN Gateway (Azure Side)
gcloud compute external-vpn-gateways create "$EXTERNAL_GW_NAME" --interfaces 0="$AZURE_PUBIP0",1="$AZURE_PUBIP1"

### - To add new connection - start here
# 4. Create VPN Tunnel 0
gcloud compute vpn-tunnels create "$TUNNEL_IF0" --peer-external-gateway="$EXTERNAL_GW_NAME" --peer-external-gateway-interface=0 --region="$GCP_REGION" --ike-version=2 --shared-secret="$SHARED_KEY" --router="$ROUTER_NAME" --vpn-gateway="$HA_VPN_GW_NAME" --interface=0

# 5. Create VPN Tunnel 1
gcloud compute vpn-tunnels create "$TUNNEL_IF1" --peer-external-gateway="$EXTERNAL_GW_NAME" --peer-external-gateway-interface=1 --region="$GCP_REGION" --ike-version=2 --shared-secret="$SHARED_KEY" --router="$ROUTER_NAME" --vpn-gateway="$HA_VPN_GW_NAME" --interface=1

# 6. Add Router Interface 0 (connects tunnel 0 to router)
gcloud compute routers add-interface "$ROUTER_NAME" --interface-name="$INTERFACE0" --vpn-tunnel="$TUNNEL_IF0" --ip-address="$GCP_APIPA_BGP_A" --mask-length=30 --region="$GCP_REGION"

# 7. Add Router Interface 1 (connects tunnel 1 to router)
gcloud compute routers add-interface "$ROUTER_NAME" --interface-name="$INTERFACE1" --vpn-tunnel="$TUNNEL_IF1" --ip-address="$GCP_APIPA_BGP_A" --mask-length=30 --region="$GCP_REGION"

# 8. Add BGP Peer 0
gcloud compute routers add-bgp-peer "$ROUTER_NAME" --peer-name="$BGP_PEER_IF0" --peer-asn="$AZURE_ASN_B" --interface="$INTERFACE0" --peer-ip-address="$AZURE_APIPA_BGP_A" --region="$GCP_REGION" --advertised-route-priority="$PRIORITY"

# 9. Add BGP Peer 1
gcloud compute routers add-bgp-peer "$ROUTER_NAME" --peer-name="$BGP_PEER_IF1" --peer-asn="$AZURE_ASN_B" --interface="$INTERFACE1" --peer-ip-address="$AZURE_APIPA_BGP_B" --region="$GCP_REGION" --advertised-route-priority="$PRIORITY"

# =========================================================================
# --- COMMANDS TO REMOVE THE HA VPN CONNECTION ---
# These must be executed in the reverse dependency order to avoid errors.
# =========================================================================

### When removing an old connection - start here
# 1. Remove BGP Peer 0
gcloud compute routers remove-bgp-peer "$ROUTER_NAME" --project="$PROJECT" --region="$GCP_REGION" --peer-name="$BGP_PEER_IF0" --quiet

# 2. Remove BGP Peer 1
gcloud compute routers remove-bgp-peer "$ROUTER_NAME" --project="$PROJECT" --region="$GCP_REGION" --peer-name="$BGP_PEER_IF1" --quiet
    
# 3. Remove Router Interface 0
gcloud compute routers remove-interface "$ROUTER_NAME" --interface-name="$INTERFACE0" --region="$GCP_REGION" --quiet
    
# 4. Remove Router Interface 1
gcloud compute routers remove-interface "$ROUTER_NAME" --interface-name="$INTERFACE1" --region="$GCP_REGION" --quiet

# 5. Delete VPN Tunnel 0
gcloud compute vpn-tunnels delete "$TUNNEL_IF0" --region="$GCP_REGION" --quiet
    
# 6. Delete VPN Tunnel 1
gcloud compute vpn-tunnels delete "$TUNNEL_IF1" --region="$GCP_REGION" --quiet

### When removing an old connection - stop here
# 7. Delete Cloud Router
gcloud compute routers delete "$ROUTER_NAME" --region="$GCP_REGION" --quiet

# 8. Delete HA VPN Gateway
gcloud compute vpn-gateways delete "$HA_VPN_GW_NAME" --region="$GCP_REGION" --quiet
    
# 9. Delete External VPN Gateway
gcloud compute external-vpn-gateways delete "$EXTERNAL_GW_NAME" --region="$GCP_REGION" --quiet


# =========================================================================
#  Single-Link VPN Setup Commands
# =========================================================================

SHARED_KEY='Q()dPJmvMHxca0(!n$Gc'

# --- Configuration Variables (Single-Link Setup) ---   
PROJECT="clouddev-itdesk124"
GCP_REGION="us-central1"
GCP_VPC="karlv-corevpc"

# Gateway, Router, External GW, and BGP ASN
HA_VPN_GW_NAME="vpn-gateway-azure-central1"
ROUTER_NAME="router-azure-central1"
EXTERNAL_GW_NAME="vpngw-single-link"
GCP_ASN="65333"

# Tunnel and Interface Names (using IF0)
TUNNEL_IF0="vpn-tunnel-azure-central1-if0"
INTERFACE0="azure-tunnel-if0"
BGP_PEER_IF0="azure-bgp-peer-if0"
PRIORITY=100

# Azure/Remote Credentials (only need one set of public/BGP IPs)
AZURE_PUBIP0="20.121.130.26" # Public IP of the remote peer gateway
AZURE_APIPA_BGP_A="169.254.21.2" # The BGP IP assigned by the remote peer for Tunnel 0
AZURE_ASN_B="65006" # The remote peer's ASN

# =========================================================================
# --- COMMANDS TO BUILD THE SINGLE-LINK VPN CONNECTION ---
# =========================================================================

echo "1. Creating HA VPN Gateway: $HA_VPN_GW_NAME"
gcloud compute vpn-gateways create "$HA_VPN_GW_NAME" \
    --network "$GCP_VPC" \
    --region "$GCP_REGION"

echo "2. Creating Cloud Router: $ROUTER_NAME"
gcloud compute routers create "$ROUTER_NAME" \
    --network "$GCP_VPC" \
    --region "$GCP_REGION" \
    --asn "$GCP_ASN"

echo "3. Creating External VPN Gateway (One Interface Only): $EXTERNAL_GW_NAME"
# Note: Only interface 0 is specified for the single link.
gcloud compute external-vpn-gateways create "$EXTERNAL_GW_NAME" \
    --interfaces 0="$AZURE_PUBIP0"

echo "4. Creating VPN Tunnel 0: $TUNNEL_IF0"
gcloud compute vpn-tunnels create "$TUNNEL_IF0" \
    --peer-external-gateway="$EXTERNAL_GW_NAME" \
    --peer-external-gateway-interface=0 \
    --region="$GCP_REGION" \
    --ike-version=2 \
    --shared-secret="$SHARED_KEY" \
    --router="$ROUTER_NAME" \
    --vpn-gateway="$HA_VPN_GW_NAME" \
    --interface=0

echo "5. Adding Router Interface 0: $INTERFACE0"
gcloud compute routers add-interface "$ROUTER_NAME" \
    --interface-name="$INTERFACE0" \
    --vpn-tunnel="$TUNNEL_IF0" \
    --region="$GCP_REGION"

echo "6. Adding BGP Peer 0: $BGP_PEER_IF0"
gcloud compute routers add-bgp-peer "$ROUTER_NAME" \
    --peer-name="$BGP_PEER_IF0" \
    --peer-asn="$AZURE_ASN_B" \
    --interface="$INTERFACE0" \
    --peer-ip-address="$AZURE_APIPA_BGP_A" \
    --region="$GCP_REGION" \
    --advertised-route-priority="$PRIORITY"

# =========================================================================
# --- COMMANDS TO REMOVE THE SINGLE-LINK VPN CONNECTION ---
# =========================================================================

echo "1. Removing BGP Peer 0: $BGP_PEER_IF0"
gcloud compute routers remove-bgp-peer "$ROUTER_NAME" --project="$PROJECT" --region="$GCP_REGION" --peer-name="$BGP_PEER_IF0" --quiet

echo "2. Removing Router Interface 0: $INTERFACE0"
gcloud compute routers remove-interface "$ROUTER_NAME" --interface-name="$INTERFACE0" --region="$GCP_REGION" --quiet

echo "3. Deleting VPN Tunnel 0: $TUNNEL_IF0"
gcloud compute vpn-tunnels delete "$TUNNEL_IF0" --region="$GCP_REGION" --quiet

echo "4. Deleting Cloud Router: $ROUTER_NAME"
gcloud compute routers delete "$ROUTER_NAME" --region="$GCP_REGION" --quiet

echo "5. Deleting HA VPN Gateway: $HA_VPN_GW_NAME"
gcloud compute vpn-gateways delete "$HA_VPN_GW_NAME" --region="$GCP_REGION" --quiet

echo "6. Deleting External VPN Gateway: $EXTERNAL_GW_NAME"
gcloud compute external-vpn-gateways delete "$EXTERNAL_GW_NAME" --region="$GCP_REGION" --quiet