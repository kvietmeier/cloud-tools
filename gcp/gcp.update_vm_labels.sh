#!/bin/bash
# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0
###############################################################################
# Script:        gcp.update_vm_labels.sh
#
# SYNOPSIS
#     Update (merge) DevOps-canonical ownership labels on a Compute Engine VM.
#
# DESCRIPTION
#     Sets GCP labels (what DevOps calls "tags"):
#         owner=<who>
#         used_by=<who>
#         longrun=true   (only with --longrun)
#
#     Choose who with one of:
#         --solutions     owner/used_by = solutions
#         --karlv         owner/used_by = karlv
#         --as NAME       owner/used_by = NAME  (custom)
#
#     longrun is presence-based (not a boolean toggle):
#         --longrun   set longrun=true (keep / do not harvest)
#         omit        remove longrun (and legacy longlived) so absence = harvestable
#
#     Also removes non-canonical keys if present: longlived, owned_by, owned, used
#
# NOTES
#     These are GCP *labels* (key=value), not network tags or Resource Manager Tags.
#     Uses the currently set gcloud project; pass --project for a different one.
#     Requires: Google Cloud SDK (gcloud)
#
# EXAMPLE
#     ./gcp.update_vm_labels.sh lab-client01 --karlv --longrun
#     ./gcp.update_vm_labels.sh lab-client01 --solutions
#     ./gcp.update_vm_labels.sh lab-client01 --as sebastien --longrun
###############################################################################

set -euo pipefail

usage() {
  echo "Usage: $0 VM_NAME (--solutions | --karlv | --as NAME) [--longrun] [--zone ZONE] [--project PROJECT_ID]"
  echo ""
  echo "  --solutions   owner=solutions, used_by=solutions"
  echo "  --karlv       owner=karlv, used_by=karlv"
  echo "  --as NAME     owner=NAME, used_by=NAME"
  echo "  --longrun     set longrun=true (keep VM); omit = remove it (harvestable)"
  exit 1
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

VM_NAME="$1"
shift

ZONE=""
PROJECT_ID=""
WHO=""
LONGRUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --solutions)
      WHO="solutions"
      shift
      ;;
    --karlv)
      WHO="karlv"
      shift
      ;;
    --as)
      [[ -n "${2:-}" ]] || usage
      WHO="$2"
      shift 2
      ;;
    --longrun)
      LONGRUN=1
      shift
      ;;
    --zone|-z)
      [[ -n "${2:-}" ]] || usage
      ZONE="$2"
      shift 2
      ;;
    --project|-p)
      [[ -n "${2:-}" ]] || usage
      PROJECT_ID="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

if [[ -z "$WHO" ]]; then
  echo "Error: choose --solutions, --karlv, or --as NAME."
  usage
fi

# GCP label values: lowercase, digits, underscores, dashes
if [[ ! "$WHO" =~ ^[a-z0-9_-]+$ ]]; then
  echo "Error: name '${WHO}' is not a valid GCP label value (use lowercase letters, digits, _ or -)."
  exit 1
fi

UPDATE_LABELS="owner=${WHO},used_by=${WHO}"
# Always strip non-canonical / legacy keys from earlier naming
REMOVE_LABELS=(longlived owned_by owned used)

if [[ "$LONGRUN" -eq 1 ]]; then
  UPDATE_LABELS="${UPDATE_LABELS},longrun=true"
else
  # Absence of longrun = harvestable
  REMOVE_LABELS+=(longrun)
fi

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
fi

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "Error: no gcloud project configured. Set one or pass --project PROJECT_ID."
  exit 1
fi

if [[ -z "$ZONE" ]]; then
  ZONE=$(gcloud compute instances list \
    --project "$PROJECT_ID" \
    --filter="name=('${VM_NAME}')" \
    --format="value(zone.scope())" \
    2>/dev/null | head -n1)
  if [[ -z "$ZONE" ]]; then
    echo "Error: VM '${VM_NAME}' not found in project '${PROJECT_ID}'."
    exit 1
  fi
fi

REMOVE_CSV=$(IFS=,; echo "${REMOVE_LABELS[*]}")

echo "Project:  $PROJECT_ID"
echo "VM:       $VM_NAME"
echo "Zone:     $ZONE"
echo "Update:   $UPDATE_LABELS"
if [[ "$LONGRUN" -eq 1 ]]; then
  echo "Longrun:  true (keep)"
else
  echo "Longrun:  absent (harvestable)"
fi
echo "Remove:   $REMOVE_CSV"
echo ""

gcloud compute instances update "$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --update-labels="$UPDATE_LABELS" \
  --remove-labels="$REMOVE_CSV"

echo ""
echo "Updated. Current labels:"
gcloud compute instances describe "$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --format="yaml(labels)"
