# Define Variables
GCP_REGION="us-central1"
TUNNEL_A="vpn-tunnel-azure-central1-if0"
TUNNEL_B="vpn-tunnel-azure-central1-if1"
ROUTER_NAME="router-azure-central1"
PEER_A="azure-bgp-peer-if0"
PEER_B="azure-bgp-peer-if1"
EXTERNAL_GW_NAME="vpngw-azure"
HA_VPN_GW_NAME="vpn-gateway-azure-central1"
NEW_KEY='Q()dPJmvMHxca0(!n$Gc'

### Policy File for Tunnel Configuration
POLICY_FILE="./robust-policy.json"

### GCP BGP Peer APIPA Addresses
GCP_BGP_IP_A="169.254.21.10"
GCP_BGP_IP_B="169.254.21.14"

### Azure BGP Peer APIPA Addresses and ASN
AZURE_APIPA_BGP_A="169.254.21.9"
AZURE_APIPA_BGP_B="169.254.21.13"
AZURE_ASN_B="65515"

# 1. DELETE OLD TUNNELS AND PEERS (Cleanup)
gcloud compute vpn-tunnels delete $TUNNEL_A --region=$GCP_REGION
gcloud compute vpn-tunnels delete $TUNNEL_B --region=$GCP_REGION
gcloud compute routers remove-bgp-peer $ROUTER_NAME --peer-name=$PEER_A --region=$GCP_REGION
gcloud compute routers remove-bgp-peer $ROUTER_NAME --peer-name=$PEER_B --region=$GCP_REGION

# 2. RECREATE TUNNELS WITH ROBUST POLICY
# --- IMPORTANT: These flags specify the required policy directly ---

# Recreate Tunnel A (Interface 0) with Robust Policy
gcloud alpha compute vpn-tunnels create $TUNNEL_A \
    --peer-external-gateway=$EXTERNAL_GW_NAME \
    --peer-external-gateway-interface=0 \
    --region=$GCP_REGION \
    --ike-version=2 \
    --shared-secret=$NEW_KEY \
    --vpn-gateway=$HA_VPN_GW_NAME \
    --interface=0 \
    --router=$ROUTER_NAME 
    #--phase1-dh=MODP_2048 \
   # --phase1-encryption=AES-256 \
   # --phase1-integrity=SHA256 \
   # --phase2-encryption=AES-256 \
   # --phase2-integrity=SHA256 \
   # --phase2-pfs=MODP_2048

# Recreate Tunnel B (Interface 1) with Robust Policy
gcloud alpha compute vpn-tunnels create $TUNNEL_B \
    --peer-external-gateway=$EXTERNAL_GW_NAME \
    --peer-external-gateway-interface=1 \
    --region=$GCP_REGION \
    --ike-version=2 \
    --shared-secret=$NEW_KEY \
    --vpn-gateway=$HA_VPN_GW_NAME \
    --interface=1 \
    --router=$ROUTER_NAME 
    #--phase1-dh=MODP_2048 \
    #--phase1-encryption=AES-256 \
    #--phase1-integrity=SHA256 \
    #--phase2-encryption=AES-256 \
    #--phase2-integrity=SHA256 \
    #--phase2-pfs=MODP_2048


####  Wait - - - - - - - 


# 3. RECREATE BGP PEERS AND ROUTER INTERFACES (Relink)
gcloud compute routers add-interface $ROUTER_NAME \
    --interface-name=azure-tunnel-if0 \
    --mask-length=30 \
    --vpn-tunnel=$TUNNEL_A \
    --ip-address=$GCP_BGP_IP_A \
    --region=$GCP_REGION
gcloud compute routers add-interface $ROUTER_NAME \
    --interface-name=azure-tunnel-if1 \
    --mask-length=30 \
    --vpn-tunnel=$TUNNEL_B \
    --ip-address=$GCP_BGP_IP_B \
    --region=$GCP_REGION

gcloud compute routers add-bgp-peer $ROUTER_NAME \
    --peer-name=$PEER_A \
    --peer-asn=$AZURE_ASN_B \
    --interface=azure-tunnel-if0 \
    --peer-ip-address=$AZURE_APIPA_BGP_A \
    --region=$GCP_REGION \
    --advertised-route-priority=100
gcloud compute routers add-bgp-peer $ROUTER_NAME \
    --peer-name=$PEER_B \
    --peer-asn=$AZURE_ASN_B \
    --interface=azure-tunnel-if1 \
    --peer-ip-address=$AZURE_APIPA_BGP_B \
    --region=$GCP_REGION \
    --advertised-route-priority=100





# CORRECTED Policy Snippet (Replacing the old commented-out lines)
gcloud alpha compute vpn-tunnels create $TUNNEL_A \
    ...
    --router=$ROUTER_NAME \
    --phase1-dh=MODP_2048 \
    --phase1-encryption=AES-CBC-256 \
    --phase1-integrity=HMAC-SHA2-256-128 \
    --phase2-encryption=AES-CBC-256 \
    --phase2-integrity=HMAC-SHA2-256-128 \
    --phase2-pfs=MODP_2048