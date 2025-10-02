#!/usr/bin/env python3
"""
===============================================================================
Title       : gcp_find_z3.py
Author      : Karl Vietmeier
Created     : 2025-09-05
License     : Apache License 2.0
Description : 
    This script performs a dry-run check to verify which GCP zones support 
    creating multiple 'z3-highmem-88-highlssd' VMs. It uses `gcloud` CLI with 
    --dry-run to validate quota, permissions, and capacity.

Usage:
    python3 gcp_find_z3.py

Notes:
    - Requires gcloud CLI installed and authenticated:
        gcloud auth application-default login
    - Dry-run does not actually create any instances.
===============================================================================
"""

import subprocess

PROJECT_ID = "YOUR_PROJECT_ID"  # Replace with your GCP project ID
MACHINE_TYPE = "z3-highmem-88-highlssd"
NUM_VMS = 1

# Hard-coded valid zones (do not modify)
VALID_ZONES = [
    "us-central1-a","us-central1-c","us-central1-f","us-central1-d",
    "europe-west1-b","europe-west1-c","europe-west1-d",
    "us-west1-a","us-west1-b","us-west1-c",
    "us-east1-b","us-east1-c","us-east1-d",
    "asia-northeast1-a","asia-northeast1-b","asia-northeast1-c",
    "asia-southeast1-a","asia-southeast1-b","asia-southeast1-c",
    "us-east4-a","us-east4-b","us-east4-c",
    "australia-southeast1-c","australia-southeast1-b",
    "europe-west2-a","europe-west2-b","europe-west2-c",
    "europe-west3-c","europe-west3-a",
    "asia-south1-b","asia-south1-c",
    "europe-west4-c","europe-west4-b","europe-west4-a",
    "us-east7-b","us-east5-c","us-east5-b","us-east5-a",
    "us-south1-c","us-south1-a","us-south1-b",
    "northamerica-south1-b","northamerica-south1-a","northamerica-south1-c",
    "europe-north2-a","europe-north2-b"
]

print(f"Dry-run results for creating {NUM_VMS} VMs of {MACHINE_TYPE}\n")
print(f"{'ZONE':<25} {'RESULT'}")
print("-"*50)

for zone in VALID_ZONES:
    cmd = [
        "gcloud", "compute", "instances", "create",
        "dry-run-test",  # temporary instance name
        f"--project={PROJECT_ID}",
        f"--zone={zone}",
        f"--machine-type={MACHINE_TYPE}",
        "--image-family=debian-11",
        "--image-project=debian-cloud",
        "--no-address",
        "--quiet",
        "--dry-run"
    ] + ["--count", str(NUM_VMS)]  # simulate multiple VMs

    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode == 0:
        print(f"{zone:<25} PASS")
    else:
        stderr = result.stderr.strip()
        if "Quota" in stderr or "permission" in stderr:
            print(f"{zone:<25} FAIL: Quota or permission issue")
        elif "does not exist" in stderr or "Invalid" in stderr:
            print(f"{zone:<25} FAIL: Invalid machine type")
        else:
            print(f"{zone:<25} FAIL: Bad request / capacity issue")
