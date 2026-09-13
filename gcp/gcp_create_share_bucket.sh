#!/usr/bin/env bash
#===========================================================
# File: gcp_create_share_bucket.sh
# Description: Create a public GCS bucket for sharing drivers,
#              ISOs, and similar files via wget/curl.
#
#              GCP Cloud Storage (not AWS S3). Public access is
#              via HTTPS URLs on storage.googleapis.com.
#
# License:
#   Copyright (c) 2026 Karl Vietmeier
#   Permission is granted to use, copy, modify, and distribute this script
#   for any purpose without fee, provided the above notice appears in all copies.
#
# Required Permissions / Roles:
#   - storage.buckets.create, storage.buckets.get, storage.buckets.setIamPolicy
#   - storage.objects.create, storage.objects.list (if uploading)
#   - serviceusage.services.enable (to enable the Storage API)
#
# Usage:
#   ./gcp_create_share_bucket.sh [BUCKET_NAME] [LOCATION] [UPLOAD_DIR]
#
# Examples:
#   ./gcp_create_share_bucket.sh
#   ./gcp_create_share_bucket.sh my-lab-share us-central1
#   ./gcp_create_share_bucket.sh my-lab-share us-central1 ./isos
#===========================================================

set -euo pipefail

#===========================================================
# Ensure gcloud is authenticated
#===========================================================
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep . >/dev/null; then
  echo "ERROR: No active gcloud account. Please run 'gcloud auth login' or activate a service account."
  exit 1
fi

#===========================================================
# Project + args
#===========================================================
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: Failed to get current GCP project. Run: gcloud config set project PROJECT_ID"
  exit 1
fi

DEFAULT_BUCKET="${PROJECT_ID}-share"
BUCKET_NAME="${1:-}"
LOCATION="${2:-us-central1}"
UPLOAD_DIR="${3:-}"

if [[ -z "$BUCKET_NAME" ]]; then
  read -r -p "Bucket name [${DEFAULT_BUCKET}]: " BUCKET_NAME
  BUCKET_NAME="${BUCKET_NAME:-$DEFAULT_BUCKET}"
fi

# Bucket names: lowercase, digits, hyphens; 3–63 chars; must start/end with letter or digit
if [[ ! "$BUCKET_NAME" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  echo "ERROR: Invalid bucket name '${BUCKET_NAME}'."
  echo "       Use 3–63 chars: lowercase letters, digits, hyphens; start/end with letter or digit."
  exit 1
fi

PUBLIC_BASE="https://storage.googleapis.com/${BUCKET_NAME}"

echo "============================================================"
echo " GCS Share Bucket Setup"
echo " Project : ${PROJECT_ID}"
echo " Bucket  : gs://${BUCKET_NAME}"
echo " Location: ${LOCATION}"
echo " Public  : ${PUBLIC_BASE}/<object>"
echo "============================================================"

#===========================================================
# Enable API + create bucket
#===========================================================
echo ""
echo "[*] Enabling Cloud Storage API..."
gcloud services enable storage.googleapis.com --project="$PROJECT_ID" >/dev/null

if gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="$PROJECT_ID" &>/dev/null; then
  echo "[*] Bucket gs://${BUCKET_NAME} already exists — reusing."
else
  echo "[*] Creating bucket gs://${BUCKET_NAME}..."
  gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --uniform-bucket-level-access \
    --public-access-prevention=inherited
fi

#===========================================================
# Public read for allUsers (wget/curl)
#===========================================================
echo "[*] Granting public objectViewer (allUsers)..."
if ! gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member=allUsers \
  --role=roles/storage.objectViewer \
  --project="$PROJECT_ID" >/dev/null; then
  echo ""
  echo "[FAIL] Could not grant allUsers public read."
  echo "       Org policy may block public buckets (constraints/storage.publicAccessPrevention"
  echo "       or domainRestrictedSharing). Ask an admin, or use signed URLs instead:"
  echo ""
  echo "  gcloud storage sign-url gs://${BUCKET_NAME}/path/to/file --duration=24h --http-verb=GET"
  exit 1
fi

# Placeholder prefixes so the layout is obvious in the console
for PREFIX in drivers iso misc; do
  echo "[*] Ensuring prefix: ${PREFIX}/"
  echo "# placeholder" | gcloud storage cp - "gs://${BUCKET_NAME}/${PREFIX}/.keep" --quiet
done

#===========================================================
# Optional upload
#===========================================================
if [[ -n "$UPLOAD_DIR" ]]; then
  if [[ ! -d "$UPLOAD_DIR" ]]; then
    echo "ERROR: Upload directory not found: ${UPLOAD_DIR}"
    exit 1
  fi
  echo "[*] Uploading contents of ${UPLOAD_DIR} -> gs://${BUCKET_NAME}/"
  gcloud storage cp -r "${UPLOAD_DIR}/"* "gs://${BUCKET_NAME}/"
fi

#===========================================================
# Print wget-ready URLs
#===========================================================
echo ""
echo "==================== Public download URLs ===================="
OBJECTS=$(gcloud storage ls -r "gs://${BUCKET_NAME}/**" 2>/dev/null | grep -v '/$' || true)

if [[ -z "$OBJECTS" ]]; then
  echo "(bucket is empty aside from placeholders)"
  echo ""
  echo "Upload examples:"
  echo "  gcloud storage cp ./virtio-win.iso gs://${BUCKET_NAME}/drivers/"
  echo "  gcloud storage cp ./install.iso   gs://${BUCKET_NAME}/iso/"
else
  while IFS= read -r OBJ; do
    [[ -z "$OBJ" ]] && continue
    # Skip .keep placeholders
    [[ "$OBJ" == *'/.keep' ]] && continue
    REL="${OBJ#gs://${BUCKET_NAME}/}"
    URL="${PUBLIC_BASE}/${REL}"
    echo "  wget '${URL}'"
  done <<< "$OBJECTS"
fi

echo ""
echo "Done. Base URL: ${PUBLIC_BASE}/"
echo "List objects:   gcloud storage ls -r gs://${BUCKET_NAME}"
echo "============================================================"
