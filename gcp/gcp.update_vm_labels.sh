#!/bin/bash
# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0
###############################################################################
# Script:        gcp.update_vm_labels.sh
#
# SYNOPSIS
#     Update (merge) ownership labels on a Compute Engine VM.
#
# DESCRIPTION
#     Sets Polaris-style labels via `gcloud compute instances update`:
#         owned_by=<who>
#         used=<who>
#         longlived=yes   (only with --longlived / --longrun)
#
#     Choose who with one of:
#         --solutions     owned_by/used = solutions
#         --karlv         owned_by/used = karlv
#         --as NAME       owned_by/used = NAME  (custom)
#
#     longlived is presence-based (not yes/no):
#         --longlived / --longrun   set longlived=yes (keep / do not harvest)
#         omit the flag             remove longlived (and legacy longrun) so
#                                   absence means harvestable
#
# NOTES
#     These are GCP *labels* (key=value), not network tags.
#     Uses the currently set gcloud project; pass --project for a different one.
#     Requires: Google Cloud SDK (gcloud)
#
# EXAMPLE
#     ./gcp.update_vm_labels.sh lab-client01 --karlv --longlived
#     ./gcp.update_vm_labels.sh lab-client01 --solutions
#     ./gcp.update_vm_labels.sh lab-client01 --as sebastien --longrun
###############################################################################

set -euo pipefail

usage() {
  echo "Usage: $0 VM_NAME (--solutions | --karlv | --as NAME) [--longlived|--longrun] [--zone ZONE] [--project PROJECT_ID]"
  echo ""
  echo "  --solutions          owned_by=solutions, used=solutions"
  echo "  --karlv              owned_by=karlv, used=karlv"
  echo "  --as NAME            owned_by=NAME, used=NAME"
  echo "  --longlived|--longrun  set longlived=yes (keep VM); omit = remove it (harvestable)"
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
LONGLIVED=0

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
    --longlived|--longrun)
      LONGLIVED=1
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

UPDATE_LABELS="owned_by=${WHO},used=${WHO}"
REMOVE_LABELS=()

if [[ "$LONGLIVED" -eq 1 ]]; then
  UPDATE_LABELS="${UPDATE_LABELS},longlived=yes"
  # Drop legacy key if present so only longlived remains
  REMOVE_LABELS+=(longrun)
else
  # Absence of longlived = harvestable; also clear legacy longrun
  REMOVE_LABELS+=(longlived longrun)
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

GCLOUD_ARGS=(
  compute instances update "$VM_NAME"
  --project "$PROJECT_ID"
  --zone "$ZONE"
  --update-labels="$UPDATE_LABELS"
)

if [[ ${#REMOVE_LABELS[@]} -gt 0 ]]; then
  # Comma-separated list for --remove-labels
  REMOVE_CSV=$(IFS=,; echo "${REMOVE_LABELS[*]}")
  GCLOUD_ARGS+=(--remove-labels="$REMOVE_CSV")
fi

echo "Project:    $PROJECT_ID"
echo "VM:         $VM_NAME"
echo "Zone:       $ZONE"
echo "Update:     $UPDATE_LABELS"
if [[ "$LONGLIVED" -eq 1 ]]; then
  echo "Longlived:  yes (keep)"
else
  echo "Longlived:  absent (harvestable); removing: ${REMOVE_LABELS[*]}"
fi
echo ""

gcloud "${GCLOUD_ARGS[@]}"

echo ""
echo "Updated. Current labels:"
gcloud compute instances describe "$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --format="yaml(labels)"
