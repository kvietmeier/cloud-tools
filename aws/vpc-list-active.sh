#!/bin/bash

# ==============================================================================
# Script: vpc-list-active.sh
# Purpose: Enumerate VPCs, Subnets, and Security Groups across all enabled AWS
#          regions for the currently authenticated session. Classifies subnets
#          as public (IGW) or private, shows AZ + free IPs, and lists SGs.
#          Accepts optional REGION and/or VPC ID:
#            ./vpc-list-active.sh
#            ./vpc-list-active.sh us-west-2
#            ./vpc-list-active.sh us-west-2 vpc-0123...
#            ./vpc-list-active.sh vpc-0123...
# ==============================================================================

TARGET_REGION=""
TARGET_VPC_ID=""

for arg in "$@"; do
    if [[ "$arg" == vpc-* ]]; then
        TARGET_VPC_ID="$arg"
    elif [[ "$arg" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]]; then
        TARGET_REGION="$arg"
    else
        echo "Error: unrecognized argument '$arg'"
        echo "Usage: $0 [region] [vpc-id]"
        exit 1
    fi
done

echo "=========================================================================="
echo " Starting VPC / Subnet / SG Enumeration"
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

# 2. Regions to scan
if [ -n "$TARGET_REGION" ]; then
    REGIONS="$TARGET_REGION"
    echo "Region filter         : $TARGET_REGION"
else
    REGIONS=$(aws ec2 describe-regions --query 'Regions[*].RegionName' --output text 2>/dev/null)
    if [ -z "$REGIONS" ]; then
        echo "Error: Unable to list AWS regions."
        exit 1
    fi
    echo "Region filter         : (all enabled regions)"
fi

FOUND_ANY=0

if [ -n "$TARGET_VPC_ID" ]; then
    echo "VPC filter            : $TARGET_VPC_ID"
else
    echo "VPC filter            : (all VPCs)"
fi
echo "=========================================================================="
echo " Subnet type: public  = default route (0.0.0.0/0) via Internet Gateway"
echo "              private = no IGW on default route (NAT or none)"
echo "=========================================================================="

# 3. Walk each region and list matching VPC(s)
for REGION in $REGIONS; do
    if [ -n "$TARGET_VPC_ID" ]; then
        VPC_IDS=$(aws ec2 describe-vpcs \
            --region "$REGION" \
            --vpc-ids "$TARGET_VPC_ID" \
            --query 'Vpcs[*].VpcId' \
            --output text 2>/dev/null)
    else
        VPC_IDS=$(aws ec2 describe-vpcs \
            --region "$REGION" \
            --query 'Vpcs[*].VpcId' \
            --output text 2>/dev/null)
    fi

    if [ -z "$VPC_IDS" ] || [ "$VPC_IDS" = "None" ]; then
        continue
    fi

    for VPC_ID in $VPC_IDS; do
        FOUND_ANY=1

        VPC_NAME=$(aws ec2 describe-vpcs \
            --region "$REGION" \
            --vpc-ids "$VPC_ID" \
            --query 'Vpcs[0].Tags[?Key==`Name`].Value | [0]' \
            --output text 2>/dev/null)
        VPC_CIDR=$(aws ec2 describe-vpcs \
            --region "$REGION" \
            --vpc-ids "$VPC_ID" \
            --query 'Vpcs[0].CidrBlock' \
            --output text 2>/dev/null)
        if [ -z "$VPC_NAME" ] || [ "$VPC_NAME" = "None" ]; then
            VPC_NAME="(no Name tag)"
        fi

        echo -e "\n######################################################################"
        echo ">>> Region: $REGION  |  VPC: $VPC_ID"
        echo ">>> Name:   $VPC_NAME  |  CIDR: $VPC_CIDR"
        echo "######################################################################"

        SUBNETS_JSON=$(aws ec2 describe-subnets \
            --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --output json)
        ROUTES_JSON=$(aws ec2 describe-route-tables \
            --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --output json)

        # Join subnets with route tables; classify public vs private via IGW
        CLASSIFIED=$(jq -n \
            --argjson subnets "$SUBNETS_JSON" \
            --argjson rts "$ROUTES_JSON" '
            ($rts.RouteTables) as $tables |
            ($tables[] | select(.Associations[]?.Main == true) | .RouteTableId) as $main_rt |
            ($tables
              | map({
                  id: .RouteTableId,
                  public: (any(.Routes[]?; .DestinationCidrBlock == "0.0.0.0/0" and (.GatewayId // "" | startswith("igw-")))),
                  gateway: ([.Routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0") | (.GatewayId // .NatGatewayId // .TransitGatewayId // .VpcPeeringConnectionId // "none")] | first // "none"),
                  subnets: [.Associations[]? | select(.SubnetId != null) | .SubnetId]
                })
            ) as $rtmap |
            ($rtmap | map(select(.id == $main_rt) | .public) | first // false) as $main_public |
            ($rtmap | map(select(.id == $main_rt) | .gateway) | first // "none") as $main_gw |
            ($subnets.Subnets
              | map(. as $s |
                  ($rtmap | map(select(.subnets | index($s.SubnetId))) | first) as $explicit |
                  {
                    type: (if $explicit then (if $explicit.public then "public" else "private" end)
                           else (if $main_public then "public" else "private" end) end),
                    id: $s.SubnetId,
                    cidr: $s.CidrBlock,
                    az: $s.AvailabilityZone,
                    free: $s.AvailableIpAddressCount,
                    name: (([$s.Tags[]? | select(.Key=="Name") | .Value] | first) // "NoName"),
                    gw: (if $explicit then $explicit.gateway else $main_gw end)
                  }
                )
              | sort_by(.type, .az, .name)
            )')

        PUBLIC_COUNT=$(echo "$CLASSIFIED" | jq '[.[] | select(.type=="public")] | length')
        PRIVATE_COUNT=$(echo "$CLASSIFIED" | jq '[.[] | select(.type=="private")] | length')
        PUBLIC_FREE=$(echo "$CLASSIFIED" | jq '[.[] | select(.type=="public") | .free] | add // 0')
        PRIVATE_FREE=$(echo "$CLASSIFIED" | jq '[.[] | select(.type=="private") | .free] | add // 0')

        echo ">>> Layout: ${PUBLIC_COUNT} public / ${PRIVATE_COUNT} private  |  free IPs: public=${PUBLIC_FREE} private=${PRIVATE_FREE}"
        if [ "$PUBLIC_COUNT" -gt 0 ] && [ "$PRIVATE_COUNT" -gt 0 ]; then
            echo ">>> Placement: usable (has both public/IGW and private subnets)"
        elif [ "$PRIVATE_COUNT" -gt 0 ]; then
            echo ">>> Placement: private-only (no IGW public subnet detected)"
        elif [ "$PUBLIC_COUNT" -gt 0 ]; then
            echo ">>> Placement: public-only (no private subnet detected)"
        else
            echo ">>> Placement: no subnets"
        fi

        echo -e "\n>>> Subnets:"
        printf "  %-8s  %-24s  %-18s  %-16s  %6s  %s\n" "TYPE" "SUBNET" "CIDR" "AZ" "FREE" "NAME"
        echo "$CLASSIFIED" | jq -r '.[] | [
            .type,
            .id,
            .cidr,
            .az,
            (.free|tostring),
            .name
          ] | @tsv' | while IFS=$'\t' read -r typ sid cidr az free name; do
            printf "  %-8s  %-24s  %-18s  %-16s  %6s  %s\n" "$typ" "$sid" "$cidr" "$az" "$free" "$name"
        done

        # Security groups in this VPC
        SGS_JSON=$(aws ec2 describe-security-groups \
            --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --output json)

        SG_COUNT=$(echo "$SGS_JSON" | jq '.SecurityGroups | length')
        echo -e "\n>>> Security Groups ($SG_COUNT):"
        printf "  %-24s  %-36s  %s\n" "SG_ID" "NAME" "DESCRIPTION"

        echo "$SGS_JSON" | jq -r '
          .SecurityGroups
          | sort_by(.GroupName)
          | .[]
          | [
              .GroupId,
              .GroupName,
              (.Description // "")
            ]
          | @tsv' | while IFS=$'\t' read -r sgid sgname sgdesc; do
            printf "  %-24s  %-36s  %s\n" "$sgid" "$sgname" "$sgdesc"
        done

        echo -e "----------------------------------------------------------------------\n"
    done
done

echo "=========================================================================="
if [ "$FOUND_ANY" -eq 0 ]; then
    msg=" No VPCs found"
    [ -n "$TARGET_REGION" ] && msg="$msg in $TARGET_REGION"
    [ -n "$TARGET_VPC_ID" ] && msg="$msg matching $TARGET_VPC_ID"
    [ -z "$TARGET_REGION" ] && [ -z "$TARGET_VPC_ID" ] && msg="$msg in any enabled region"
    echo "${msg}."
else
    echo " Enumeration Complete!"
fi
echo "=========================================================================="
