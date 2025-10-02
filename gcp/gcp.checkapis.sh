#!/bin/bash
###==========================================================================================================### 
#
#  For GCP:
#  Check from a list of required APIs whether they are enabled or not.
#
#   Created by: Karl Vietmeier
#   License: Apache License 2.0
#   SPDX-License-Identifier: Apache-2.0
#   Copyright 2025 Karl Vietmeier
#
###==========================================================================================================### 


# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Installing..."
    sudo apt-get install jq -y || sudo yum install jq -y
fi

# Fetch the list of available APIs
API_LIST=$(curl -s https://www.googleapis.com/discovery/v1/apis | jq '.')

# Define the required APIs
REQUIRED_APIS=(
	"Service Networking"
    "Cloud Functions API"
    "Artifact Registry"
    "Cloud Build API"
	"Compute Engine API"
	"Network Management API"
	"Service Networking API"
	"Network Security API"
	"Cloud Monitoring API"
	"Cloud Logging API"
	"Secret Manager"
)

echo "Checking required Google Cloud APIs..."

# Check if each API is available
for API in "${REQUIRED_APIS[@]}"; do
    if echo "$API_LIST" | grep -q "$API"; then
        echo "[✔] $API is available."
    else
        echo "[✖] $API is NOT available!"
    fi
done

