#!/bin/bash

# ==============================================================================
# Script: enum-vpcs-active.sh
# Purpose: Enumerate VPCs and Subnets for the currently authenticated AWS session.
#          Accepts an optional VPC ID argument to target a single VPC.
# ==============================================================================

echo "=========================================================================="
echo " Starting VPC and Subnet Enumeration"
echo "=========================================================================="

# 1. Verify current authentication
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
CURRENT_ARN=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)

if [ -z "$CURRENT_ACCOUNT" ]; then
    echo "Error: No active AWS authentication found. Please log in first."
    exit 1
fi

echo "Authenticated Account : $CURRENT_ACCOUNT"
echo "Authenticated Identity: $CURRENT_ARN"
echo "=========================================================================="

# 2. Determine target VPC(s) based on CLI arguments
if [ -n "$1" ]; then
    # If an argument is provided, use it as the sole VPC ID
    echo "Targeting specific VPC provided via CLI: $1"
    VPC_IDS="$1"
else
    # If no argument is provided, fetch all VPCs in the region
    echo "No specific VPC provided. Discovering all VPCs..."
    VPC_IDS=$(aws ec2 describe-vpcs --query 'Vpcs[*].VpcId' --output text)
    
    if [ -z "$VPC_IDS" ]; then
        echo "No VPCs found in the current authenticated environment."
        exit 0
    fi
fi

# 3. Loop through the designated VPC ID(s)
for VPC_ID in $VPC_IDS; do
    
    echo -e "\n######################################################################"
    echo ">>> Details for VPC: $VPC_ID"
    echo "######################################################################"
    
    # 4. Show the VPC details in table format
    aws ec2 describe-vpcs \
        --vpc-ids "$VPC_ID" \
        --query 'Vpcs[*].{Name:Tags[?Key==`Name`]|[0].Value,VpcId:VpcId,CidrBlock:CidrBlock}' \
        --output table

    echo -e "\n>>> Associated Subnets:"
    
    # 5. Show the subnets using the jq parsing logic
    aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" | \
        jq -r '.Subnets[] | [ .SubnetId, .CidrBlock, (.Tags[]? | select(.Key=="Name").Value // "NoName") ] | join("  ")'

    echo -e "----------------------------------------------------------------------\n"

done

echo "=========================================================================="
echo " Enumeration Complete!"
echo "=========================================================================="