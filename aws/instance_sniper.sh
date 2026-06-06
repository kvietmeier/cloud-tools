#!/usr/bin/env bash
# ==============================================================================
# Script: capacity_sweep.sh
# Description: Automated capacity probe for AWS EC2 On-Demand Capacity Reservations (ODCR).
#              Loops through a predefined list of Availability Zones to secure constrained 
#              resources (e.g., i3en.24xlarge) for VAST cluster deployments.
#              Defaults to immediate cancellation to verify hardware availability 
#              without incurring On-Demand compute billing.
#
# Usage: ./capacity_sweep.sh <instance-count> <zones-file-path> [delay-in-seconds] [auto-cancel: y/n]
#
# Copyright 2026
# Licensed under the Apache License, Version 2.0
# ==============================================================================

# Validate input
if [ -z "$2" ]; then
    echo "Usage: $0 <instance-count> <zones-file-path> [delay-in-seconds] [auto-cancel: y/n]"
    exit 1
fi

# Assign CLI arguments to variables
INSTANCE_COUNT=$1
ZONES_FILE=$2
DELAY_SECONDS=${3:-1800} # Defaults to 1800s (30m) if left blank
AUTO_CANCEL=${4:-y}      # Defaults to 'y' (cancel immediately)

INSTANCE_TYPE="i3en.24xlarge"

# Verify the zones file exists
if [ ! -f "$ZONES_FILE" ]; then
    echo "❌ Error: Zones file '$ZONES_FILE' not found."
    exit 1
fi

# The efficient, macOS-compatible file reader 
# (Ignores blank lines and commented lines starting with # or spaces followed by #)
mapfile -t ZONES < <(grep -E -v '^[[:space:]]*#' "$ZONES_FILE" | grep -E -v '^[[:space:]]*$')

echo "Starting Capacity Reservation sweep..."
echo "Instances: $INSTANCE_COUNT x $INSTANCE_TYPE"
echo "Zones loaded from $ZONES_FILE: ${ZONES[*]}"
echo "Retry delay: $DELAY_SECONDS seconds."
echo "--------------------------------------------------"

while true; do
    AVAILABLE_ZONES=()
    
    for ZONE in "${ZONES[@]}"; do
        echo "[$(date)] Probing $ZONE..."

        # Run the creation command and capture output
        OUTPUT=$(aws ec2 create-capacity-reservation \
            --instance-type $INSTANCE_TYPE \
            --instance-platform Linux/UNIX \
            --availability-zone $ZONE \
            --instance-count $INSTANCE_COUNT \
            --instance-match-criteria open \
            --output json 2>&1)

        # Check if the AWS CLI command was successful
        if [ $? -eq 0 ]; then
            echo "✅ SUCCESS! Capacity found in $ZONE."
            
            # Extract the Reservation ID (starts with cr-)
            RESERVATION_ID=$(echo "$OUTPUT" | grep -o '"CapacityReservationId": "[^"]*' | grep -o 'cr-[a-zA-Z0-9]*')
            AVAILABLE_ZONES+=("$ZONE")
            
            # Auto-cancel logic to avoid On-Demand charges
            if [[ "$AUTO_CANCEL" =~ ^[Yy]$ ]]; then
                echo "   -> Sweeping mode: Canceling $RESERVATION_ID to avoid charges..."
                aws ec2 cancel-capacity-reservation --capacity-reservation-id "$RESERVATION_ID" > /dev/null
            else
                echo "   -> Keeping the reservation. Hardware locked in $ZONE!"
                echo "Capacity secured. Exiting."
                exit 0
            fi
        else
            echo "❌ Capacity unavailable in $ZONE."
        fi
    done

    # If capacity was found during this sweep and we are in auto-cancel mode, summarize and exit
    if [ ${#AVAILABLE_ZONES[@]} -gt 0 ] && [[ "$AUTO_CANCEL" =~ ^[Yy]$ ]]; then
        echo ""
        echo "🎉 SWEEP COMPLETE! Capacity is currently available in the following zones:"
        for Z in "${AVAILABLE_ZONES[@]}"; do
            echo "  - $Z"
        done
        echo ""
        echo "To lock in this capacity, copy and run the following command for your preferred zone:"
        echo "--------------------------------------------------"
        echo "aws ec2 create-capacity-reservation \\"
        echo "    --instance-type $INSTANCE_TYPE \\"
        echo "    --instance-platform Linux/UNIX \\"
        echo "    --availability-zone <CHOOSE-ONE-ZONE-FROM-ABOVE> \\"
        echo "    --instance-count $INSTANCE_COUNT \\"
        echo "    --instance-match-criteria open"
        echo "--------------------------------------------------"
        break
    fi

    # If no capacity was found, trigger the sleep delay before sweeping again
    echo "Sweep complete. No capacity found. Sleeping for $DELAY_SECONDS seconds before retrying..."
    sleep "$DELAY_SECONDS"
done