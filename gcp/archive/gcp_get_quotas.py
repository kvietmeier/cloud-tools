#!/usr/bin/env python3
"""
==================================================
Karl Vietmeier
VAST Data
GCP Quota Summary Script

This script retrieves and displays all GCP quotas
for a given project and region. It shows the metric,
limit, current usage, remaining quota, and percentage
used, sorted alphabetically by metric.

License: Apache License 2.0
Author: Karl Vietmeier
==================================================
"""

import subprocess
import json
import sys

# --- Configurable column widths ---
METRIC_WIDTH = 50
NUM_WIDTH = 12
PERCENT_WIDTH = 10

def fetch_quotas(project: str, region: str):
    """Fetch GCP quotas for a given project and region using gcloud."""
    try:
        result = subprocess.run(
            ["gcloud", "compute", "regions", "describe", region, "--project", project, "--format=json"],
            capture_output=True,
            text=True,
            check=True
        )
        data = json.loads(result.stdout)
        return data.get("quotas", [])
    except subprocess.CalledProcessError as e:
        print(e.stderr)
        sys.exit(1)

def display_quotas(quotas: list):
    """Print quotas in a formatted table, sorted by metric name."""
    header = f"{'METRIC'.ljust(METRIC_WIDTH)}{'LIMIT'.rjust(NUM_WIDTH)}{'USAGE'.rjust(NUM_WIDTH)}{'REMAINING'.rjust(NUM_WIDTH)}{'USED_%'.rjust(PERCENT_WIDTH)}"
    print(header)
    print("-" * (METRIC_WIDTH + NUM_WIDTH*3 + PERCENT_WIDTH))

    for quota in sorted(quotas, key=lambda x: x.get("metric", "")):
        metric = quota.get("metric")
        limit = quota.get("limit")
        usage = quota.get("usage")

        # Handle special cases
        if limit > 1e18:
            limit_display = "UNLIMITED"
            remaining = "UNLIMITED"
            used_percent = "0"
        elif limit == 0:
            limit_display = "0"
            remaining = "0"
            used_percent = "N/A"
        else:
            limit_display = f"{int(limit)}"
            remaining = f"{int(limit - usage)}"
            used_percent = f"{usage/limit*100:.2f}"

        print(f"{metric.ljust(METRIC_WIDTH)}{limit_display.rjust(NUM_WIDTH)}{str(int(usage)).rjust(NUM_WIDTH)}{remaining.rjust(NUM_WIDTH)}{used_percent.rjust(PERCENT_WIDTH)}")

def main():
    """Main entry point."""
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} PROJECT REGION")
        sys.exit(1)

    project = sys.argv[1]
    region = sys.argv[2]

    quotas = fetch_quotas(project, region)
    display_quotas(quotas)

if __name__ == "__main__":
    main()
