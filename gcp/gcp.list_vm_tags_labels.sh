#!/bin/bash
# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0
###############################################################################
# Script:        gcp.list_vm_tags_labels.sh
#
# SYNOPSIS
#     List network tags and labels for every Compute Engine VM in the project.
#
# DESCRIPTION
#     Uses `gcloud compute instances list` (JSON) and formats:
#         - VM name, zone, status
#         - Network tags (tags.items)
#         - Labels (key=value map)
#
# NOTES
#     Requires: Google Cloud SDK (gcloud), jq
#     Uses the currently set gcloud project; pass --project for a different one.
#
# EXAMPLE
#     ./gcp.list_vm_tags_labels.sh
#     ./gcp.list_vm_tags_labels.sh --project my-gcp-project
###############################################################################

set -euo pipefail

PROJECT_ID=""
if [[ "${1:-}" == "--project" || "${1:-}" == "-p" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "Usage: $0 [--project PROJECT_ID]"
    exit 1
  fi
  PROJECT_ID="$2"
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--project PROJECT_ID]"
  exit 1
else
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
fi

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "Error: no gcloud project configured. Set one or pass --project PROJECT_ID."
  exit 1
fi

json=$(gcloud compute instances list --project "$PROJECT_ID" --format=json)

COUNT=$(echo "$json" | jq 'length')

echo ""
echo "==================== VM Tags & Labels ===================="
echo "Project: $PROJECT_ID"
echo "Total VMs: $COUNT"
echo "=========================================================="
echo ""

if [[ "$COUNT" -eq 0 ]]; then
  echo "No instances found."
  exit 0
fi

# One block per VM (readable when labels/tags are long)
# Note: network tags (tags.items) != console "Tags" (org resource tags).
echo "$json" | jq -r '
  .[] |
  (.name) as $name |
  (if (.zone | type) == "string" then (.zone | split("/") | last) else "unknown" end) as $zone |
  (.status // "UNKNOWN") as $status |
  (
    if ((.tags.items | type) == "array") and ((.tags.items | length) > 0)
    then (.tags.items | join(", "))
    else "(none)"
    end
  ) as $tags |
  (
    if ((.labels | type) == "object") and ((.labels | length) > 0)
    then (.labels | to_entries | map("\(.key)=\(.value)") | join(", "))
    else "(none)"
    end
  ) as $labels |
  "VM:            \($name)\nZone:          \($zone)\nStatus:        \($status)\nNetwork tags:  \($tags)\nLabels:        \($labels)\n----------------------------------------------------------"
'

# Compact summary table — labels first (Polaris / DevOps care about these)
echo ""
echo "-------------------- Compact table -----------------------"
printf "%-32s %-16s %-12s %-55s %s\n" "NAME" "ZONE" "STATUS" "LABELS" "NETWORK_TAGS"
echo "$json" | jq -r '
  .[] |
  [
    .name,
    (if (.zone | type) == "string" then (.zone | split("/") | last) else "unknown" end),
    (.status // "UNKNOWN"),
    (if ((.labels | type) == "object") and ((.labels | length) > 0)
     then (.labels | to_entries | map("\(.key)=\(.value)") | join(","))
     else "-"
     end),
    (if ((.tags.items | type) == "array") and ((.tags.items | length) > 0)
     then (.tags.items | join(","))
     else "-"
     end)
  ] | @tsv
' | while IFS=$'\t' read -r name zone status labels tags; do
  printf "%-32s %-16s %-12s %-55s %s\n" "$name" "$zone" "$status" "$labels" "$tags"
done
echo ""
