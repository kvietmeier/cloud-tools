#!/bin/bash

###############################################################################
# Script:        gcp.voc_ip_orphan_scan.sh
#
# SYNOPSIS
#     Project-wide: match INTERNAL VoC VIP/IP reservations to live VMs
#     (or flag them as orphaned after cluster teardown).
#
# DESCRIPTION
#     1. Lists INTERNAL addresses (default: purpose=GCE_ENDPOINT — VoC VIP style)
#     2. Groups them by cluster prefix (strips -mgmt-vip, -internal-NNNNN, etc.)
#     3. Lists voc-internal instances once and maps them to those prefixes
#     4. Verdict per cluster:
#          ORPHAN  — RESERVED addrs remain, no RUNNING/STAGING voc-internal VMs
#          LIVE    — at least one live voc-internal VM for the prefix
#          EMPTY   — no addrs and no VMs (should not appear)
#
#     Use when a project has dozens of RESERVED/IN_USE GCE_ENDPOINT rows and
#     you need to know which clusters are gone vs still running.
#
# NOTES
#     Requires: gcloud, jq, python3
#     Author: Karl Vietmeier
#     Per-cluster deep dive: ./gcp.voc_alias_attach_audit.sh <CLUSTER>
#
# USAGE
#     ./gcp.voc_ip_orphan_scan.sh [options]
#
# OPTIONS
#     -p, --project PROJECT   GCP project (default: current gcloud config)
#     --all-internal          Include all INTERNAL addresses (not only GCE_ENDPOINT)
#     --orphans-only          Print only ORPHAN clusters
#     --delete-cmds           Print suggested gcloud delete lines for orphans
#     --json-dir DIR          Write raw addresses/instances JSON
#     -h, --help              Show help
#
# EXAMPLES
#     ./gcp.voc_ip_orphan_scan.sh
#     ./gcp.voc_ip_orphan_scan.sh -p vast-on-cloud --orphans-only --delete-cmds
###############################################################################

set -euo pipefail

PROJECT_ID=""
ALL_INTERNAL=0
ORPHANS_ONLY=0
DELETE_CMDS=0
JSON_DIR=""

usage() {
  sed -n '3,45p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_ID="$2"; shift 2 ;;
    --all-internal) ALL_INTERNAL=1; shift ;;
    --orphans-only) ORPHANS_ONLY=1; shift ;;
    --delete-cmds) DELETE_CMDS=1; shift ;;
    --json-dir) JSON_DIR="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
    *)
      echo "Unexpected argument: $1" >&2
      usage 1
      ;;
  esac
done

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || {
  echo "No project set. Pass -p/--project or run: gcloud config set project <id>" >&2
  exit 1
}

GCLOUD=(gcloud --project="$PROJECT_ID")
if [[ -n "$JSON_DIR" ]]; then
  mkdir -p "$JSON_DIR"
fi

echo "========================================================================"
echo " VoC IP Orphan Scan (project-wide)"
echo " Project: $PROJECT_ID"
echo " Filter:  $([[ "$ALL_INTERNAL" -eq 1 ]] && echo 'addressType=INTERNAL' || echo 'INTERNAL + purpose=GCE_ENDPOINT')"
echo "========================================================================"

if [[ "$ALL_INTERNAL" -eq 1 ]]; then
  ADDR_FILTER="addressType=INTERNAL"
else
  ADDR_FILTER="addressType=INTERNAL AND purpose=GCE_ENDPOINT"
fi

echo ""
echo "[1] Fetching addresses + voc-internal instances"
echo "------------------------------------------------------------------------"

# Large projects blow past ARG_MAX if JSON is passed via env; use temp files.
TMP_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap 'rm -rf "$TMP_DIR"' EXIT
ADDR_FILE="${TMP_DIR}/addresses.json"
INST_FILE="${TMP_DIR}/instances.json"

"${GCLOUD[@]}" compute addresses list \
  --filter="$ADDR_FILTER" \
  --format=json >"$ADDR_FILE"
"${GCLOUD[@]}" compute instances list \
  --filter="tags.items=voc-internal" \
  --format=json >"$INST_FILE"

if [[ -n "$JSON_DIR" ]]; then
  cp "$ADDR_FILE" "${JSON_DIR}/addresses.json"
  cp "$INST_FILE" "${JSON_DIR}/instances-voc-internal.json"
fi

ADDR_COUNT="$(jq 'length' "$ADDR_FILE")"
INST_COUNT="$(jq 'length' "$INST_FILE")"
echo "  addresses=${ADDR_COUNT}  voc-internal VMs=${INST_COUNT}"

export VOC_ADDR_FILE="$ADDR_FILE"
export VOC_INST_FILE="$INST_FILE"
export VOC_PROJECT="$PROJECT_ID"
export VOC_ORPHANS_ONLY="$ORPHANS_ONLY"
export VOC_DELETE_CMDS="$DELETE_CMDS"

python3 <<'PY'
import json, os, re, sys
from collections import defaultdict

with open(os.environ["VOC_ADDR_FILE"]) as f:
    addrs = json.load(f)
with open(os.environ["VOC_INST_FILE"]) as f:
    insts = json.load(f)
project = os.environ["VOC_PROJECT"]
orphans_only = os.environ.get("VOC_ORPHANS_ONLY") == "1"
delete_cmds = os.environ.get("VOC_DELETE_CMDS") == "1"

# Longest-first so -mgmt-inner-vip wins over -mgmt-vip
SUFFIX_RE = re.compile(
    r"(?:"
    r"-k3s-control-plane-vip|"
    r"-mgmt-inner-vip|"
    r"-mgmt-vip|"
    r"-dns-vip|"
    r"-internal-\d+|"
    r"-enode-in-[0-9a-fA-F-]+"
    r")$"
)

def cluster_key(name: str) -> str:
    name = name or ""
    prev = None
    while prev != name:
        prev = name
        name = SUFFIX_RE.sub("", name)
    return name

LIVE = {"RUNNING", "STAGING"}

# VMs indexed for prefix / label match
vms = []
for i in insts:
    labels = i.get("labels") or {}
    cn = labels.get("cluster_name") or ""
    vms.append({
        "name": i.get("name") or "",
        "status": i.get("status") or "",
        "zone": (i.get("zone") or "").split("/")[-1],
        "cluster_name": cn,
        "live": (i.get("status") or "") in LIVE,
    })

by_cluster = defaultdict(lambda: {
    "addrs": [],
    "reserved": 0,
    "in_use": 0,
    "regions": set(),
    "live_vms": [],
    "other_vms": [],
})

for a in addrs:
    name = a.get("name") or ""
    key = cluster_key(name)
    if not key:
        key = name or "(unnamed)"
    entry = by_cluster[key]
    entry["addrs"].append(a)
    st = a.get("status") or ""
    if st == "RESERVED":
        entry["reserved"] += 1
    elif st == "IN_USE":
        entry["in_use"] += 1
    region = (a.get("region") or "").split("/")[-1]
    if region:
        entry["regions"].add(region)

# Match VMs to address-derived clusters
for key, entry in by_cluster.items():
    for v in vms:
        hit = False
        if v["cluster_name"] and (
            v["cluster_name"] == key
            or key.startswith(v["cluster_name"] + "-")
            or v["cluster_name"].startswith(key + "-")
            or (key.endswith("-gcp") and v["cluster_name"] == key[:-4])
            or key == v["cluster_name"] + "-gcp"
        ):
            hit = True
        elif v["name"] == key or v["name"].startswith(key + "-"):
            hit = True
        if not hit:
            continue
        if v["live"]:
            entry["live_vms"].append(v)
        else:
            entry["other_vms"].append(v)

# Also surface live voc-internal clusters with zero matching addresses
addr_keys = set(by_cluster.keys())
vm_only = defaultdict(list)
for v in vms:
    if not v["live"]:
        continue
    label = v["cluster_name"] or "(no-cluster_name)"
    # Skip if already covered by an address group match
    covered = False
    for key in addr_keys:
        e = by_cluster[key]
        if v in e["live_vms"] or v in e["other_vms"]:
            covered = True
            break
    if not covered:
        vm_only[label].append(v)

print("")
print("[2] Per-cluster verdict")
print("-" * 72)
hdr = f"{'VERDICT':<8} {'CLUSTER':<42} {'ADDRS':>5} {'RES':>4} {'INUSE':>5} {'LIVE_VM':>7}  REGIONS"
print(hdr)
print("-" * len(hdr))

orphan_clusters = []
live_clusters = []
weird = []

for key in sorted(by_cluster.keys()):
    e = by_cluster[key]
    n_live = len({v["name"] for v in e["live_vms"]})
    n_addr = len(e["addrs"])
    regions = ",".join(sorted(e["regions"])) or "-"

    if n_live == 0 and e["reserved"] > 0:
        verdict = "ORPHAN"
        orphan_clusters.append(key)
    elif n_live == 0 and e["in_use"] > 0:
        # IN_USE but no voc-internal VM — users may point at deleted/non-VAST
        verdict = "STALE?"
        weird.append(key)
    elif n_live > 0:
        verdict = "LIVE"
        live_clusters.append(key)
    else:
        verdict = "EMPTY"
        continue

    if orphans_only and verdict != "ORPHAN":
        continue

    print(
        f"{verdict:<8} {key:<42} {n_addr:>5} {e['reserved']:>4} {e['in_use']:>5} "
        f"{n_live:>7}  {regions}"
    )

if not orphans_only and vm_only:
    print("")
    print("[2b] Live voc-internal VMs with no matching GCE_ENDPOINT address group")
    print("-" * 72)
    for label in sorted(vm_only.keys()):
        names = sorted({v["name"] for v in vm_only[label]})
        print(f"  LIVE     {label:<42} vms={len(names)}  ({', '.join(names[:3])}{'...' if len(names) > 3 else ''})")

print("")
print("[3] Summary")
print("-" * 72)
if orphans_only:
    print(f"  orphan clusters shown: {len(orphan_clusters)}")
else:
    print(f"  clusters with addresses: {len(by_cluster)}")
    print(f"  LIVE:   {len(live_clusters)}")
    print(f"  ORPHAN: {len(orphan_clusters)}  (RESERVED leak, no live voc-internal VMs)")
    print(f"  STALE?: {len(weird)}  (IN_USE but no live voc-internal VM)")

if orphan_clusters:
    print("")
    print("[4] Orphan detail (RESERVED, no live VMs)")
    print("-" * 72)
    for key in orphan_clusters:
        e = by_cluster[key]
        print(f"  {key}")
        for a in sorted(e["addrs"], key=lambda x: x.get("address") or ""):
            if a.get("status") != "RESERVED":
                continue
            ip = a.get("address") or "-"
            name = a.get("name") or "-"
            region = (a.get("region") or "").split("/")[-1] or "-"
            print(f"      {ip:<15} {region:<14} {name}")
        if e["other_vms"]:
            for v in e["other_vms"]:
                print(f"      (non-live VM) {v['name']} status={v['status']} zone={v['zone']}")

if delete_cmds and orphan_clusters:
    print("")
    print("[5] Suggested cleanup (review before running)")
    print("-" * 72)
    for key in orphan_clusters:
        e = by_cluster[key]
        for a in sorted(e["addrs"], key=lambda x: (x.get("name") or "")):
            if a.get("status") != "RESERVED":
                continue
            name = a.get("name")
            region = (a.get("region") or "").split("/")[-1]
            if not name or not region:
                continue
            print(
                f"  # gcloud compute addresses delete {name} "
                f"--region={region} --project={project} --quiet"
            )
    print("")
    print("  Deep dive one cluster:")
    print(f"    ./gcp.voc_alias_attach_audit.sh <CLUSTER> -p {project} --no-logs")

# Exit: 3 if orphans (same convention as per-cluster audit)
rc = 3 if orphan_clusters else 0
print("")
print("=" * 72)
if rc == 3:
    print(f"RESULT: ORPHAN leaks found ({len(orphan_clusters)} cluster prefix(es)) (exit 3)")
else:
    print("RESULT: No orphaned RESERVED address groups (exit 0)")
sys.exit(rc)
PY
