#!/usr/bin/env bash
# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0
#===========================================================
# File: gcp.setupnewvpc.sh
# Description: Creates a multi-region custom VPC.
# Ports: set PORT_FILE to manifests/ports.example.txt|.json|.yml (or ports.txt).
#              - 3 subnets in 3 regions (expandable)
#              - Cloud Routers + NAT in each region
#              - Private Google Access enabled on all subnets
#              - Global firewall rules for RFC1918, GCP services, and app ports
#
# Required Permissions / Roles:
#   - VPC & Subnets: compute.networks.create, compute.networks.update,
#     compute.subnetworks.create, compute.subnetworks.update
#   - Routers & NAT: compute.routers.create, compute.routers.update, compute.routers.get, compute.routers.list
#   - Firewall Rules: compute.firewalls.create, compute.firewalls.update, compute.firewalls.get, compute.firewalls.list
#   - API Enablement: serviceusage.services.enable
#   - General: resourcemanager.projects.get
#
#   Simplest: If you are a Project Owner in your GCP project, you already have all required permissions.
#===========================================================


set -euo pipefail

_GCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/manifest.sh
source "${_GCP_DIR}/lib/manifest.sh"

#===========================================================
# Ensure gcloud is authenticated
#===========================================================
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep . >/dev/null; then
  echo "ERROR: No active gcloud account. Please run 'gcloud auth login' or activate a service account."
  exit 1
fi


#===========================================================
# Get current GCP project
#===========================================================
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: Failed to get current GCP project. Please run 'gcloud config set project PROJECT_ID' first."
  exit 1
fi
echo "Using GCP project: $PROJECT_ID"


#===========================================================
# Configurable variables
#===========================================================
VPC_NAME="lab-vpc"
# Optional: ports.txt, or manifests/ports.example.json|.yml|.txt
PORT_FILE="${GCP_PORTS_MANIFEST:-./ports.txt}"

declare -A REGIONS=(
  ["us-central1"]="10.0.0.0/20"
  ["us-east1"]="10.1.0.0/20"
  ["us-west1"]="10.2.0.0/20"
)

REQUIRED_APIS=(
  servicenetworking.googleapis.com
  cloudfunctions.googleapis.com
  artifactregistry.googleapis.com
  cloudbuild.googleapis.com
  compute.googleapis.com
  networkmanagement.googleapis.com
  networksecurity.googleapis.com
  monitoring.googleapis.com
  logging.googleapis.com
  secretmanager.googleapis.com
)

DEFAULT_FIREWALLS=(
  default-allow-icmp
  default-allow-internal
  default-allow-rdp
  default-allow-ssh
)

#===========================================================
# Functions
#===========================================================

enable_apis() {
  echo ">>> Enabling required Google Cloud APIs..."
  for API in "${REQUIRED_APIS[@]}"; do
    echo "Enabling ${API}..."
    gcloud services enable "${API}" || echo "${API} already enabled, continuing..."
  done
  echo ">>> All required APIs enabled."
}

delete_default_vpc() {
  echo ">>> Deleting default firewall rules and VPC (if they exist)..."
  for FW in "${DEFAULT_FIREWALLS[@]}"; do
    if gcloud compute firewall-rules describe "${FW}" &> /dev/null; then
      echo "Deleting firewall rule: ${FW}"
      gcloud compute firewall-rules delete "${FW}" --quiet
    fi
  done

  if gcloud compute networks describe default &> /dev/null; then
    echo "Deleting default VPC"
    gcloud compute networks delete default --quiet
  fi
}

create_vpc() {
  echo ">>> Creating VPC: ${VPC_NAME}"
  gcloud compute networks create "${VPC_NAME}" --subnet-mode=custom || echo "VPC ${VPC_NAME} already exists, continuing..."
}

create_subnets_and_nat() {
  for REGION in "${!REGIONS[@]}"; do
    SUBNET_NAME="${VPC_NAME}-${REGION}-subnet"
    ROUTER_NAME="${VPC_NAME}-${REGION}-router"
    NAT_NAME="${VPC_NAME}-${REGION}-nat"
    RANGE="${REGIONS[$REGION]}"

    echo ">>> Creating Subnet: ${SUBNET_NAME} in ${REGION}"
    gcloud compute networks subnets create "${SUBNET_NAME}" \
      --network="${VPC_NAME}" \
      --region="${REGION}" \
      --range="${RANGE}" || echo "Subnet ${SUBNET_NAME} already exists, continuing..."

    echo ">>> Enabling Private Google Access on ${SUBNET_NAME}"
    gcloud compute networks subnets update "${SUBNET_NAME}" \
      --region="${REGION}" \
      --enable-private-ip-google-access

    echo ">>> Creating Router: ${ROUTER_NAME} in ${REGION}"
    gcloud compute routers create "${ROUTER_NAME}" \
      --network="${VPC_NAME}" \
      --region="${REGION}" || echo "Router ${ROUTER_NAME} already exists, continuing..."

    echo ">>> Creating NAT: ${NAT_NAME} in ${REGION}"
    gcloud compute routers nats create "${NAT_NAME}" \
      --router="${ROUTER_NAME}" \
      --region="${REGION}" \
      --nat-all-subnet-ip-ranges \
      --auto-allocate-nat-external-ips || echo "NAT ${NAT_NAME} already exists, continuing..."
  done
}

create_firewall_rules() {
  echo ">>> Creating firewall rule: internal RFC1918"
  gcloud compute firewall-rules create "${VPC_NAME}-allow-internal" \
    --network="${VPC_NAME}" \
    --allow=tcp,udp,icmp \
    --source-ranges=10.0.0.0/8 \
    --description="Allow internal RFC1918 traffic" || echo "Firewall rule already exists, continuing..."

  echo ">>> Creating firewall rule: GCP services"
  gcloud compute firewall-rules create "${VPC_NAME}-allow-gcp-services" \
    --network="${VPC_NAME}" \
    --allow=tcp,udp,icmp \
    --source-ranges=35.191.0.0/16,130.211.0.0/22,199.36.153.4/30,199.36.153.8/30,35.235.240.0/20,35.199.192.0/19 \
    --description="Allow GCP health checks, IAP, Private APIs, Cloud DNS" || echo "Firewall rule already exists, continuing..."

  # Load optional port manifest (JSON/YAML/TXT). Falls back to built-in defaults.
  if [[ -f "${PORT_FILE}" ]]; then
    echo ">>> Loading ports from ${PORT_FILE}"
    load_ports_manifest "${PORT_FILE}"
    PORTS=""
    local p port proto lab
    for p in "${REQUIRED_PORTS[@]}"; do
      IFS=":" read -r port proto lab <<< "$p"
      [[ -n "$PORTS" ]] && PORTS+=","
      PORTS+="${proto}:${port}"
    done
  else
    echo ">>> No ${PORT_FILE} found, using default ports (edit script or set PORT_FILE / GCP_PORTS_MANIFEST)"
    PORTS="tcp:22,tcp:80,tcp:443,tcp:389,tcp:636"
  fi

  echo ">>> Creating firewall rule: application ports"
  gcloud compute firewall-rules create "${VPC_NAME}-allow-ports" \
    --network="${VPC_NAME}" \
    --allow="${PORTS}" \
    --source-ranges=0.0.0.0/0 \
    --description="Allow required TCP/UDP application ports" || echo "Firewall rule already exists, continuing..."
}

#===========================================================
# Main
#===========================================================
enable_apis
delete_default_vpc
create_vpc
create_subnets_and_nat
create_firewall_rules

echo ">>> Multi-region VPC with PGA and firewall setup complete!"
