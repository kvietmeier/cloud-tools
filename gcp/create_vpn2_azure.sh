# Define Variables

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

# GCP BGP Peer IPs (As expected by Azure config)
GCP_BGP_IP_A="169.254.21.1" # Your side's IP
GCP_BGP_IP_B="169.254.22.1" # Your second side's IP


### From Azure - 
NEW_KEY='Q()dPJmvMHxca0(!n$Gc'
AZURE_PUBIP0="20.121.130.26"
AZURE_PUBIP1="172.172.233.46"
# We must use the 169.254.x.x addresses for Azure here to avoid the 400 error.
AZURE_APIPA_BGP_A="169.254.21.2"   # Example: The other side of the 169.254.21.8/30 network
AZURE_APIPA_BGP_B="169.254.22.2"  # Example: The other side of the 169.254.21.12/30 network
AZURE_ASN_B="65006"

### Create GWs and router
gcloud compute vpn-gateways create \
    $HA_VPN_GW_NAME \
    --network $GCP_VPC \
    --region $GCP_REGION

gcloud compute routers create \
    $ROUTER_NAME \
    --network $GCP_VPC \
    --region $GCP_REGION \
    --asn $GCP_ASN

gcloud compute external-vpn-gateways create \
    $EXTERNAL_GW_NAME \
    --interfaces 0=$AZURE_PUBIP0,1=$AZURE_PUBIP1


### Tunnels
# Tunnel 0 (to Azure Public IP 1)
gcloud compute vpn-tunnels create $TUNNEL_IF0 \
    --peer-external-gateway=$EXTERNAL_GW_NAME \
    --peer-external-gateway-interface=0 \
    --region=$GCP_REGION \
    --ike-version=2 \
    --shared-secret=$NEW_KEY \
    --router=$ROUTER_NAME \
    --vpn-gateway=$HA_VPN_GW_NAME \
    --interface=0

# Tunnel 1 (to Azure Public IP 2)
gcloud compute vpn-tunnels create $TUNNEL_IF1 \
    --peer-external-gateway=$EXTERNAL_GW_NAME \
    --peer-external-gateway-interface=1 \
    --region=$GCP_REGION \
    --ike-version=2 \
    --shared-secret=$NEW_KEY \
    --router=$ROUTER_NAME \
    --vpn-gateway=$HA_VPN_GW_NAME \
    --interface=1

# Interfaces
gcloud compute routers add-interface $ROUTER_NAME \
    --interface-name=$INTERFACE0\
    --vpn-tunnel=$TUNNEL_IF0 \
    --region=$GCP_REGION

gcloud compute routers add-interface $ROUTER_NAME \
    --interface-name=$INTERFACE1 \
    --vpn-tunnel=$TUNNEL_IF1 \
    --region=$GCP_REGION

### BGP Peers
# BGP Peer for Tunnel 0: Target Azure BGP APIPA IP
gcloud compute routers add-bgp-peer $ROUTER_NAME \
    --peer-name=$BGP_PEER_IF0 \
    --peer-asn=$AZURE_ASN_B \
    --interface=$INTERFACE0 \
    --peer-ip-address=$AZURE_APIPA_BGP_A \
    --region=$GCP_REGION \
    --advertised-route-priority=$PRIORITY

# BGP Peer for Tunnel 1: Target Azure BGP APIPA IP
gcloud compute routers add-bgp-peer $ROUTER_NAME \
    --peer-name=$BGP_PEER_IF1 \
    --peer-asn=$AZURE_ASN_B \
    --interface=$INTERFACE1 \
    --peer-ip-address=$AZURE_APIPA_BGP_B \
    --region=$GCP_REGION \
    --advertised-route-priority=$PRIORITY


### Test connectivity from GCP to Azure VM (assumes SSH allowed in Azure NSG)

###==================== Remove things when done  =======================###

# Remove BGP Peers
gcloud compute routers remove-bgp-peer $ROUTER_NAME \
    --project=$PROJECT \
    --region=$GCP_REGION \
    --peer-name=$BGP_PEER_IF1

gcloud compute routers remove-bgp-peer $ROUTER_NAME \
    --project=$PROJECT \
    --region=$GCP_REGION \   
    --peer-name=$BGP_PEER_IF1

# Delete VPN Tunnels
gcloud compute vpn-tunnels delete $TUNNEL_IF1 --region=$GCP_REGION 
gcloud compute vpn-tunnels delete $TUNNEL_IF0 --region=$GCP_REGION

# Delete Gateways and Router
gcloud compute routers delete $ROUTER_NAME --region=$GCP_REGION
gcloud compute vpn-gateways delete $HA_VPN_GW_NAME --region=$GCP_REGION
gcloud compute external-vpn-gateways delete $EXTERNAL_GW_NAME --region=$GCP_REGION