#!/bin/bash
# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0
###############################################################################
# Script:        gcp.update_vm_labels.sh
#
# SYNOPSIS
#     Update (merge) labels on a Compute Engine VM.
#
# DESCRIPTION
#     Applies key=value labels via `gcloud compute instances update --update-labels`.
#     Existing labels are kept; matching keys are overwritten.
#
#     Defaults (override with --labels):
#         longrun=yes
#         owner=karlv
#         used_by=karlv
#
# NOTES
#     These are GCP *labels* (key=value), not network tags.
#     Uses the currently set gcloud project; pass --project for a different one.
#     Requires: Google Cloud SDK (gcloud)
#
# EXAMPLE
#     ./gcp.update_vm_labels.sh lab-client01
#     ./gcp.update_vm_labels.sh lab-client01 --zone us-central1-a
#     ./gcp.update_vm_labels.sh lab-client01 --project my-gcp-project
#     ./gcp.update_vm_labels.sh lab-client01 --labels longrun=yes,owner=karlv,used_by=karlv
###############################################################################

set -euo pipefail

usage() {
  echo "Usage: $0 VM_NAME [--zone ZONE] [--project PROJECT_ID] [--labels key=val,...]"
  echo ""
  echo "Defaults labels: longrun=yes,owner=karlv,used_by=karlv"
  exit 1
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

VM_NAME="$1"
shift

ZONE=""
PROJECT_ID=""
LABELS="longrun=yes,owner=karlv,used_by=karlv"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --labels|-l)
      [[ -n "${2:-}" ]] || usage
      LABELS="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

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

echo "Project: $PROJECT_ID"
echo "VM:      $VM_NAME"
echo "Zone:    $ZONE"
echo "Labels:  $LABELS"
echo ""

gcloud compute instances update "$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --update-labels="$LABELS"

echo ""
echo "Updated. Current labels:"
gcloud compute instances describe "$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --format="yaml(labels)"
