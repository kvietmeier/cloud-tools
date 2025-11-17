#!/bin/bash
# =========================================
# TPU Calendar Mode Availability Checker
# Created by Karl Vietmeier / VAST Data
# =========================================

# --------- USER PARAMETERS ---------
# TPU chip count (must match valid options)
NUMBER_OF_CHIPS=8

# TPU version (V6E, V5E, V5P)
TPU_VERSION="V6E"

# TPU workload type (only needed for V5E)
WORKLOAD_TYPE=""  # Options: BATCH or SERVING, leave empty for V6E/V5P

# GCP region
REGION="us-central1"

# Start time range (RFC 3339)
FROM_START_TIME="2025-10-21T09:00:00-07:00"
TO_START_TIME="2025-10-21T10:00:00-07:00"

# End time range (RFC 3339)
FROM_END_TIME="2025-10-22T09:00:00-07:00"
TO_END_TIME="2025-10-22T18:00:00-07:00"

# --------- COMMAND CONSTRUCTION ---------
CMD="gcloud alpha compute advice calendar-mode \
    --chip-count=${NUMBER_OF_CHIPS} \
    --tpu-version=${TPU_VERSION} \
    --region=${REGION} \
    --start-time-range=from=${FROM_START_TIME},to=${TO_START_TIME} \
    --end-time-range=from=${FROM_END_TIME},to=${TO_END_TIME}"

# Add workload type flag if V5E is used
if [ "$TPU_VERSION" == "V5E" ] && [ -n "$WORKLOAD_TYPE" ]; then
    CMD="$CMD --workload-type=${WORKLOAD_TYPE}"
fi

# --------- EXECUTE COMMAND ---------
echo "Running TPU calendar-mode availability check..."
echo "Command: $CMD"
echo
eval $CMD
