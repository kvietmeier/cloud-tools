#!/bin/bash
# cloud-whoami.sh - Rapid Identity Check for VAST SEs

# Colors for easy reading
GREEN='\033[0;32m'
BLUE='\033[0;34m'
ORANGE='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}--- Cloud Identity & VAST Status ---${NC}"

# 1. VAST VMS Status
echo -ne "VAST VMS: "
if [ -n "$VMS_ADDRESS" ]; then
    echo -e "${GREEN}${VMS_USER}@${VMS_ADDRESS}${NC}"
else
    echo -e "${RED}NOT SET${NC}"
fi

# 2. Azure Check
echo -ne "Azure:    "
if command -v az &> /dev/null; then
    AZ_USER=$(az account show --query 'user.name' -o tsv 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${AZ_USER}${NC}"
    else
        echo -e "${ORANGE}Not logged in (az login)${NC}"
    fi
else
    echo -e "${RED}CLI not found${NC}"
fi

# 3. GCP Check
echo -ne "GCP:      "
if command -v gcloud &> /dev/null; then
    GCP_USER=$(gcloud config get-value account 2>/dev/null)
    GCP_PROJ=$(gcloud config get-value project 2>/dev/null)
    if [ -n "$GCP_USER" ]; then
        echo -e "${GREEN}${GCP_USER}${NC} (Proj: ${GCP_PROJ})"
    else
        echo -e "${ORANGE}Not logged in (gcloud auth login)${NC}"
    fi
else
    echo -e "${RED}CLI not found${NC}"
fi

# 4. AWS Check
echo -ne "AWS:      "
if command -v aws &> /dev/null; then
    # Using --timeout to prevent hanging in data centers with no route to AWS
    AWS_USER=$(aws sts get-caller-identity --query 'Arn' --output tsv --cli-connect-timeout 2 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${AWS_USER}${NC}"
    else
        echo -e "${ORANGE}No valid session (aws sso login)${NC}"
    fi
else
    echo -e "${RED}CLI not found${NC}"
fi

echo -e "${BLUE}------------------------------------${NC}"
