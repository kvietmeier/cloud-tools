#!/bin/bash

# ==============================================================================
# Script: list-subnet-instances.sh
# Purpose: Find EC2 instances and their current state within specific AWS Subnets.
# Usage: ./list-subnet-instances.sh [subnet-id] 
#        OR export SUBNET_ID=<subnet-id> 
#        OR place a 'subnets.txt' file in the same directory.
# ==============================================================================

echo "=========================================================================="
echo " Starting Subnet Instance Enumeration"
echo "=========================================================================="

# 1. Verify current authentication
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
if [ -z "$CURRENT_ACCOUNT" ]; then
    echo "Error: No active AWS authentication found. Please log in first."
    exit 1
fi
echo "AWS Account : $CURRENT_ACCOUNT"
echo "=========================================================================="
echo ""

# 2. Define the reusable function to process a single subnet
enumerate_instances() {
    local target_subnet=$1
    echo ">>> Target Subnet: $target_subnet"
    
    (
        # Print the header row
        echo -e "INSTANCE_ID\tSTATE\tPRIVATE_IP\tNAME"
        
        # Run the AWS CLI command and process with jq
        aws ec2 describe-instances \
            --filters "Name=subnet-id,Values=$target_subnet" \
            --output json | jq -r '
            .Reservations[].Instances[] |
            .InstanceId as $id |
            .State.Name as $state |
            (.PrivateIpAddress // "NO_IP") as $ip |
            
            # Safely extract the Name tag, defaulting to NO_NAME if missing
            (if .Tags != null then (first(.Tags[] | select(.Key=="Name") | .Value) // "NO_NAME") else "NO_NAME" end) as $name |
            
            "\($id)\t\($state)\t\($ip)\t\($name)"
        ' | sort
    ) | column -t # Align columns cleanly based on tabs
    
    echo -e "----------------------------------------------------------------------\n"
}

# 3. Determine our targets and load them into an array
TARGET_SUBNETS=()

if [ -n "$1" ]; then
    echo "Using CLI argument for subnet."
    TARGET_SUBNETS+=("$1")
elif [ -n "$SUBNET_ID" ]; then
    echo "Using SUBNET_ID environment variable."
    TARGET_SUBNETS+=("$SUBNET_ID")
elif [ -f "subnets.txt" ]; then
    echo "Found subnets.txt. Reading subnets from file..."
    while IFS= read -r line || [ -n "$line" ]; do
        # Clean up whitespace and skip empty lines or comments
        line=$(echo "$line" | xargs)
        if [[ -n "$line" && ! "$line" =~ ^# ]]; then
            TARGET_SUBNETS+=("$line")
        fi
    done < "subnets.txt"
else
    echo "Error: No target subnets provided."
    echo "Usage 1: $0 <subnet-id>"
    echo "Usage 2: export SUBNET_ID=<subnet-id>; $0"
    echo "Usage 3: Create a 'subnets.txt' file in this directory."
    exit 1
fi

# 4. Loop through the array of targets and run our function
for subnet in "${TARGET_SUBNETS[@]}"; do
    enumerate_instances "$subnet"
done

echo "=========================================================================="
echo " Enumeration Complete!"
echo "=========================================================================="