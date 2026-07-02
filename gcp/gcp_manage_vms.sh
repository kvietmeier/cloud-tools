#!/bin/bash
# ====================================================================================
# gcp_manage_client_vms
# Usage: gcp_manage_client_vms <start|stop|resume|list> [count] [type: lab|gateway]
#        gcp_manage_client_vms <start|stop|resume|list> [type: lab|gateway]
# ====================================================================================
# Function to safely manage batches of Google Cloud VM instances in parallel.
# - Action: "start", "stop", "resume", or "list"
# - Count: Optional integer to limit the number of VMs processed (default: all)
# - Type: Optional target selection, either "lab" or "gateway" (default: lab)
#
# Operational Highlights:
#   - Auto-shifts positional arguments if count is omitted (e.g., 'list gateway').
#   - Queries global runtime matrices in 1 single, efficient API call.
#   - Minimizes API mutations by skipping VMs already in the desired target state.
#   - Executes gcloud state changes in async parallel background threads.
#   - Bypasses interactive CLI confirmations with native tracking hooks.
# ====================================================================================

gcp_manage_client_vms() {
    local ACTION=$1
    local COUNT=$2
    local TYPE=$3

    # Smart Auto-Shift: If the 2nd argument is an explicit asset type type instead of a number
    if [[ "$COUNT" == "gateway" || "$COUNT" == "lab" ]]; then
        TYPE=$COUNT
        COUNT=0
    fi
    
    # Enforce strict default fallbacks
    COUNT=${COUNT:-0}
    TYPE=${TYPE:-lab}

    if [[ "$ACTION" != "start" && "$ACTION" != "stop" && "$ACTION" != "resume" && "$ACTION" != "list" ]]; then
        echo "Error: Action must be start, stop, resume, or list."
        echo "Usage: gcp_manage_client_vms [action] [optional_count] [optional_type: lab|gateway]"
        return 1
    fi

    # 1. Define Managed Resource Footprints
    local ALL_VMS=()
    local FILTER_STRING=""

    if [[ "$TYPE" == "gateway" ]]; then
        FILTER_STRING="name:voc-gateway*"
        ALL_VMS=("voc-gateway" "voc-gateway2" "voc-gateway3" "voc-gateway4" "voc-gateway5" \
                 "voc-gateway6" "voc-gateway7" "voc-gateway8" "voc-gateway9" "voc-gateway10" \
                 "voc-gateway11" "voc-gateway12" "voc-gateway13" "voc-gateway14" "voc-gateway15" \
                 "voc-gateway16" "voc-gateway17" "voc-gateway18" "voc-gateway19" "voc-gateway20")
    else
        FILTER_STRING="name:labgroup*"
        ALL_VMS=("labgroup01" "labgroup02" "labgroup03" "labgroup04" "labgroup05" \
                 "labgroup06" "labgroup07" "labgroup08" "labgroup09" "labgroup10" \
                 "labgroup11" "labgroup12" "labgroup13" "labgroup14" "labgroup15" \
                 "labgroup16" "labgroup17" "labgroup18" "labgroup19" "labgroup20")
    fi

    # Slice array footprint if a count ceiling is explicitly specified
    if [[ $COUNT -gt 0 && $COUNT -le ${#ALL_VMS[@]} ]]; then
        ALL_VMS=("${ALL_VMS[@]:0:$COUNT}")
    fi

    echo "Fetching VM status from Compute Engine API..."
    
    # Dynamic Batch Query based on targeted asset type
    local STATE_MATRIX
    STATE_MATRIX=$(gcloud compute instances list \
        --filter="$FILTER_STRING" \
        --format="value(name,status,zone.scope())")

    declare -A VM_ZONES
    declare -A VM_STATUSES
    declare -A JOB_PIDS
    declare -A FINAL_OUTCOMES

    # Parse state matrix into memory mapping arrays
    while read -r name status zone; do
        if [[ -n "$name" ]]; then
            VM_STATUSES["$name"]="$status"
            VM_ZONES["$name"]="$zone"
        fi
    done <<< "$STATE_MATRIX"

    # Handle Read-Only List Path
    if [[ "$ACTION" == "list" ]]; then
        echo ""
        echo "========================================================"
        echo "          CURRENT VM INVENTORY ($TYPE)           "
        echo "========================================================"
        printf "%-15s | %-12s | %-15s\n" "VM NAME" "STATUS" "ZONE"
        echo "--------------------------------------------------------"
        for VM in "${ALL_VMS[@]}"; do
            local TARGET_ZONE="${VM_ZONES[$VM]:-UNKNOWN}"
            local CURRENT_STATUS="${VM_STATUSES[$VM]:-NOT FOUND}"
            printf "%-15s | %-12s | %-15s\n" "$VM" "$CURRENT_STATUS" "$TARGET_ZONE"
        done
        echo "========================================================"
        return 0
    fi

    # Disable job control reporting to keep terminal output clean
    set +m

    for VM in "${ALL_VMS[@]}"; do
        local TARGET_ZONE="${VM_ZONES[$VM]}"
        local CURRENT_STATUS="${VM_STATUSES[$VM]}"

        if [[ -z "$TARGET_ZONE" ]]; then
            echo "[-] Error: Instance $VM not found in active project metadata inventory."
            FINAL_OUTCOMES["$VM"]="Not Found"
            continue
        fi

        # Skip evaluation logic to minimize unnecessary API mutations
        if [[ "$ACTION" == "stop" && ("$CURRENT_STATUS" == "TERMINATED" || "$CURRENT_STATUS" == "STOPPING") ]]; then
            echo "[=] $VM is already $CURRENT_STATUS. Skipping."
            FINAL_OUTCOMES["$VM"]="Skipped (Already Inactive)"
            continue
        elif [[ "$ACTION" == "start" && "$CURRENT_STATUS" == "RUNNING" ]]; then
            echo "[=] $VM is already RUNNING. Skipping."
            FINAL_OUTCOMES["$VM"]="Skipped (Already Running)"
            continue
        fi

        echo "[+] Dispatching $ACTION request for $VM in $TARGET_ZONE..."

        # Async execution block with interactive prompts disabled via --quiet
        if [[ "$ACTION" == "start" && "$CURRENT_STATUS" == "SUSPENDED" ]]; then
            gcloud compute instances resume "$VM" --zone="$TARGET_ZONE" --quiet &>/dev/null &
        else
            gcloud compute instances "$ACTION" "$VM" --zone="$TARGET_ZONE" --quiet &>/dev/null &
        fi
        
        JOB_PIDS["$VM"]=$!
    done

    echo "----------------------------------------------------------------"
    echo "Awaiting parallel processing threads to resolve state changes..."
    echo "----------------------------------------------------------------"

    # Trap background PIDs directly using your sequential array layout
    for VM in "${ALL_VMS[@]}"; do
        if [[ -n "${JOB_PIDS[$VM]}" ]]; then
            wait "${JOB_PIDS[$VM]}"
            if [[ $? -eq 0 ]]; then
                FINAL_OUTCOMES["$VM"]="Success"
            else
                FINAL_OUTCOMES["$VM"]="Failed"
            fi
        fi
    done

    # Reset standard terminal job tracking behavior
    set -m

    echo ""
    echo "========================================================"
    echo "             VM State Change Summary ($TYPE)             "
    echo "========================================================"
    for VM in "${ALL_VMS[@]}"; do
        printf "Result for %-15s : %s\n" "$VM" "${FINAL_OUTCOMES[$VM]:-Skipped}"
    done
    echo "========================================================"
}
