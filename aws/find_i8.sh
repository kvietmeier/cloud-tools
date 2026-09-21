#!/usr/bin/env bash
# Find Availability Zones where i8g / i8ge instance families are offered.
# One line per AZ: which families are present (not every size).

set -euo pipefail

for region in $(aws ec2 describe-regions --query "Regions[].RegionName" --output text); do
  offerings=$(aws ec2 describe-instance-type-offerings \
    --region "$region" \
    --location-type availability-zone \
    --filters Name=instance-type,Values="i8g.*","i8ge.*" \
    --query 'InstanceTypeOfferings[*].[Location, InstanceType]' \
    --output text 2>/dev/null || true)

  [ -z "$offerings" ] && continue

  summary=$(printf '%s\n' "$offerings" | awk '
    {
      az = $1
      type = $2
      if (type ~ /^i8ge\./) i8ge[az] = 1
      else if (type ~ /^i8g\./) i8g[az] = 1
      seen[az] = 1
    }
    END {
      for (az in seen) {
        parts = ""
        if (i8g[az]) parts = "i8g"
        if (i8ge[az]) {
          if (parts != "") parts = parts ", "
          parts = parts "i8ge"
        }
        print az "\t" parts
      }
    }' | sort)

  [ -z "$summary" ] && continue

  echo "========== $region =========="
  printf '%s\n' "$summary"
  echo
done
