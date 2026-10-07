#!/bin/bash
# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0
# ------------------------------------------------------------------------------
# Shared manifest loaders for IAM permissions and firewall ports.
# Supports .json (jq), .yml/.yaml (yq or PyYAML), and ports .txt lists.
# ------------------------------------------------------------------------------

# Convert a JSON or YAML file to JSON on stdout.
manifest_to_json() {
    local file=$1
    if [[ ! -f "$file" ]]; then
        echo "[FAIL] Manifest not found: $file" >&2
        return 1
    fi
    case "${file##*.}" in
        json)
            jq -e . "$file" >/dev/null || { echo "[FAIL] Invalid JSON: $file" >&2; return 1; }
            cat "$file"
            ;;
        yml|yaml)
            if command -v yq &>/dev/null; then
                # mikefarah/yq (Go) or kislyuk/yq (Python) — try both shapes
                if yq -o=json '.' "$file" 2>/dev/null; then
                    return 0
                elif yq -o json "$file" 2>/dev/null; then
                    return 0
                elif yq eval -o=json "$file" 2>/dev/null; then
                    return 0
                fi
            fi
            if python3 -c 'import yaml' 2>/dev/null; then
                python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$file"
                return 0
            fi
            echo "[FAIL] YAML manifest requires yq or PyYAML. Install one, or use a .json file." >&2
            return 1
            ;;
        *)
            echo "[FAIL] Unsupported manifest extension: $file (use .json, .yml, .yaml)" >&2
            return 1
            ;;
    esac
}

# Load IAM permission groups into PERM_GROUPS (assoc) and PERM_GROUP_ORDER (array).
# Manifest shapes:
#   { "order": ["Group"], "groups": { "Group": ["perm.a", "perm.b"] } }
#   { "groups": { "Group": ["perm.a"] } }
#   { "groups": [ { "name": "Group", "permissions": ["perm.a"] } ] }
load_permissions_manifest() {
    local file=$1
    local json
    json=$(manifest_to_json "$file") || return 1

    PERM_GROUP_ORDER=()
    unset PERM_GROUPS
    declare -gA PERM_GROUPS

    local shape
    shape=$(echo "$json" | jq -r '
      if (.groups|type)=="object" then "object"
      elif (.groups|type)=="array" then "array"
      else "invalid" end')

    if [[ "$shape" == "invalid" ]]; then
        echo "[FAIL] Permissions manifest needs a top-level \"groups\" object or array." >&2
        return 1
    fi

    if [[ "$shape" == "object" ]]; then
        mapfile -t PERM_GROUP_ORDER < <(echo "$json" | jq -r '
            if (.order|type)=="array" and (.order|length)>0 then .order[]
            else .groups|keys_unsorted[] end')
        local name
        for name in "${PERM_GROUP_ORDER[@]}"; do
            PERM_GROUPS["$name"]=$(echo "$json" | jq -r --arg n "$name" '
                (.groups[$n] // []) | if type=="array" then join(" ") else empty end')
            if [[ -z "${PERM_GROUPS[$name]}" ]]; then
                echo "[WARN] Empty or missing permissions for group: $name" >&2
            fi
        done
    else
        mapfile -t PERM_GROUP_ORDER < <(echo "$json" | jq -r '.groups[].name')
        local name
        for name in "${PERM_GROUP_ORDER[@]}"; do
            PERM_GROUPS["$name"]=$(echo "$json" | jq -r --arg n "$name" '
                .groups[] | select(.name==$n) | (.permissions // []) | join(" ")')
        done
    fi

    if [[ ${#PERM_GROUP_ORDER[@]} -eq 0 ]]; then
        echo "[FAIL] No permission groups found in $file" >&2
        return 1
    fi
    echo "[INFO] Loaded ${#PERM_GROUP_ORDER[@]} permission group(s) from $file"
}

# Load REQUIRED_PORTS as "port:proto:label" entries.
# Supports:
#   .json / .yml: { "ports": [ {"port":"22","proto":"tcp","label":"SSH"}, "443:tcp:HTTPS" ] }
#   .txt: one of  tcp:22  |  22:tcp:SSH  |  tcp:22:SSH   per line (# comments ok)
load_ports_manifest() {
    local file=$1
    REQUIRED_PORTS=()

    if [[ ! -f "$file" ]]; then
        echo "[FAIL] Ports manifest not found: $file" >&2
        return 1
    fi

    case "${file##*.}" in
        txt|list)
            local line port proto label
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%%#*}"
                # trim whitespace without xargs (sandbox-safe)
                line="${line#"${line%%[![:space:]]*}"}"
                line="${line%"${line##*[![:space:]]}"}"
                [[ -z "$line" ]] && continue
                if [[ "$line" =~ ^([0-9]+(-[0-9]+)?):(tcp|udp):(.+)$ ]]; then
                    REQUIRED_PORTS+=("$line")
                elif [[ "$line" =~ ^(tcp|udp):([0-9]+(-[0-9]+)?):(.+)$ ]]; then
                    proto="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"; label="${BASH_REMATCH[4]}"
                    REQUIRED_PORTS+=("${port}:${proto}:${label}")
                elif [[ "$line" =~ ^(tcp|udp):([0-9]+(-[0-9]+)?)$ ]]; then
                    proto="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
                    REQUIRED_PORTS+=("${port}:${proto}:${port}")
                else
                    echo "[WARN] Skipping unrecognized port line: $line" >&2
                fi
            done < "$file"
            ;;
        json|yml|yaml)
            local json
            json=$(manifest_to_json "$file") || return 1
            mapfile -t REQUIRED_PORTS < <(echo "$json" | jq -r '
                (.ports // [])[] |
                if type=="string" then
                  .
                else
                  "\(.port):\(.proto // "tcp"):\(.label // (.port|tostring))"
                end')
            ;;
        *)
            echo "[FAIL] Unsupported ports manifest: $file (use .json, .yml, .yaml, or .txt)" >&2
            return 1
            ;;
    esac

    if [[ ${#REQUIRED_PORTS[@]} -eq 0 ]]; then
        echo "[FAIL] No ports found in $file" >&2
        return 1
    fi
    echo "[INFO] Loaded ${#REQUIRED_PORTS[@]} port(s) from $file"
}

# Apply built-in default permission groups when no manifest is provided.
load_default_permissions() {
    unset PERM_GROUPS
    declare -gA PERM_GROUPS=(
        ["Cloud Functions"]="cloudfunctions.functions.create cloudfunctions.functions.delete cloudfunctions.functions.get cloudfunctions.functions.getIamPolicy cloudfunctions.functions.setIamPolicy cloudfunctions.operations.get"
        ["Compute Engine"]="compute.addresses.createInternal compute.addresses.deleteInternal compute.addresses.get compute.addresses.setLabels compute.addresses.useInternal compute.disks.create compute.disks.setLabels compute.healthChecks.create compute.healthChecks.delete compute.healthChecks.get compute.healthChecks.use compute.images.get compute.images.useReadOnly compute.instanceGroupManagers.create compute.instanceGroupManagers.delete compute.instanceGroupManagers.get compute.instanceGroups.create compute.instanceGroups.delete compute.instanceGroups.get compute.instanceTemplates.create compute.instanceTemplates.delete compute.instanceTemplates.get compute.instanceTemplates.useReadOnly compute.instances.create compute.instances.get compute.instances.setLabels compute.instances.setMetadata compute.instances.setTags compute.regionOperations.get compute.subnetworks.get compute.subnetworks.use compute.resourcePolicies.create compute.resourcePolicies.delete compute.resourcePolicies.get"
        ["IAM & SAs"]="iam.roles.create iam.roles.delete iam.roles.get iam.roles.undelete iam.serviceAccounts.actAs iam.serviceAccounts.create iam.serviceAccounts.delete iam.serviceAccounts.get"
        ["Resource Manager"]="resourcemanager.projects.get resourcemanager.projects.getIamPolicy resourcemanager.projects.setIamPolicy"
        ["Secret Manager"]="secretmanager.secrets.create secretmanager.secrets.delete secretmanager.secrets.get secretmanager.versions.access secretmanager.versions.add secretmanager.versions.destroy secretmanager.versions.enable secretmanager.versions.get"
        ["Cloud Storage"]="storage.buckets.create storage.buckets.delete storage.buckets.get storage.objects.create storage.objects.delete storage.objects.get"
    )
    PERM_GROUP_ORDER=("Cloud Functions" "Compute Engine" "IAM & SAs" "Resource Manager" "Secret Manager" "Cloud Storage")
}

# Apply built-in default ports when no manifest is provided.
load_default_ports() {
    REQUIRED_PORTS=(
        "22:tcp:SSH"
        "80:tcp:HTTP"
        "443:tcp:HTTPS"
        "389:tcp:LDAP"
        "636:tcp:LDAPS"
    )
}
