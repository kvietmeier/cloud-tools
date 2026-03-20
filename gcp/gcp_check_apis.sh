#!/bin/bash

###==========================================================================================================###
###
###  Check if required GCP APIs are ENABLED in the current project.
###  Requires: gcloud CLI and jq
###
###==========================================================================================================###

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Installing..."
    sudo apt-get install jq -y || sudo yum install jq -y
fi

# Get current project ID
PROJECT_ID=$(gcloud config get-value project)
if [[ -z "$PROJECT_ID" ]]; then
    echo "GCP project not set. Run: gcloud config set project [PROJECT_ID]"
    exit 1
fi

# Define the required API service names (NOT human-readable names)
REQUIRED_SERVICES=(
    "servicenetworking.googleapis.com"
    "cloudfunctions.googleapis.com"
    "artifactregistry.googleapis.com"
    "cloudbuild.googleapis.com"
    "compute.googleapis.com"
    "networkmanagement.googleapis.com"
    "networksecurity.googleapis.com"
    "monitoring.googleapis.com"
    "logging.googleapis.com"
    "secretmanager.googleapis.com"
)

# Get currently enabled APIs
ENABLED_SERVICES=$(gcloud services list --enabled --format="value(config.name)")

echo "Checking enabled Google Cloud APIs for project: $PROJECT_ID"

for SERVICE in "${REQUIRED_SERVICES[@]}"; do
    if echo "$ENABLED_SERVICES" | grep -q "$SERVICE"; then
        echo "[✔] $SERVICE is enabled."
    else
        echo "[✖] $SERVICE is NOT enabled!"
    fi
done

