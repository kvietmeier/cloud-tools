#!/bin/bash

###############################################################################
# Script:        gcp.voc_alias_attach_audit.sh
#
# SYNOPSIS
#     Audit VoC cluster VIP reservations vs GCE alias IPs on eNode NICs,
#     and surface updateNetworkInterface races / fingerprint failures.
#
# DESCRIPTION
#     For a given CLUSTER_NAME this script:
#       1. Lists reserved INTERNAL addresses named <cluster>-*
#       2. Finds Polaris/VoC nodes: network tag voc-internal (on every
#          cluster node) AND (label cluster_name=... OR name prefix)
#       3. Compares reserved VIP/internal IPs to nic0 aliasIpRanges
#       4. Lists recent zone updateNetworkInterface ops (incl. BAD REQUEST)
#       5. Optionally reads Cloud Audit Logs for alias attach payloads
#
#     Typical failure mode: installer SA fires concurrent NIC updates with
#     partial alias lists + stale fingerprint -> Invalid fingerprint /
#     missing aliases even though addresses are RESERVED.
#
# NOTES
#     Requires: gcloud, jq, python3
#     Author: Karl Vietmeier
#
#     Canonical home: git.vastdata.com:karlv/sre-runbooks (vastcloud/scripts/).
#     Forensics write-up (private): vastcloud/VastCloud-GCP-VIP-Alias-Attach-Forensics.md
#     A copy of this script may also live in the public cloud-tools repo for convenience.
#
# USAGE
#     ./gcp.voc_alias_attach_audit.sh <CLUSTER_NAME> [options]
#
# OPTIONS
#     -p, --project PROJECT     GCP project (default: current gcloud config)
#     -z, --zone ZONE           Limit instance/ops lookup to one zone
#     -s, --since RFC3339|DATE  Ops/logs since (default: yesterday UTC date)
#     --no-logs                 Skip Cloud Audit Logs (ops + inventory only)
#     --json-dir DIR            Write raw JSON dumps to DIR
#     -h, --help                Show help
#
# EXAMPLES
#     ./gcp.voc_alias_attach_audit.sh seb-wmt-test
#     ./gcp.voc_alias_attach_audit.sh seb-wmt-test -p vast-on-cloud -z us-central1-a
#     ./gcp.voc_alias_attach_audit.sh eiki-vko-gcp-1 --since 2026-09-20 --json-dir /tmp/voc-audit
###############################################################################

set -euo pipefail

CLUSTER_NAME=""
PROJECT_ID=""
ZONE=""
SINCE=""
DO_LOGS=1
JSON_DIR=""

usage() {
  sed -n '3,45p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_ID="$2"; shift 2 ;;
    -z|--zone) ZONE="$2"; shift 2 ;;
    -s|--since) SINCE="$2"; shift 2 ;;
    --no-logs) DO_LOGS=0; shift ;;
    --json-dir) JSON_DIR="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
    *)
      if [[ -z "$CLUSTER_NAME" ]]; then
        CLUSTER_NAME="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage 1
      fi
      ;;
  esac
done

if [[ -z "$CLUSTER_NAME" ]]; then
  read -r -p "Cluster name: " CLUSTER_NAME
fi
[[ -n "$CLUSTER_NAME" ]] || { echo "CLUSTER_NAME is required" >&2; exit 1; }

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || {
  echo "No project set. Pass -p/--project or run: gcloud config set project <id>" >&2
  exit 1
}

if [[ -z "$SINCE" ]]; then
  if date -u -d 'yesterday' +%Y-%m-%d >/dev/null 2>&1; then
    SINCE="$(date -u -d 'yesterday' +%Y-%m-%d)"
  else
    SINCE="$(date -u -v-1d +%Y-%m-%d)"
  fi
fi

SINCE_OPS="$SINCE"
SINCE_LOGS="$SINCE"
if [[ "$SINCE_LOGS" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  SINCE_LOGS="${SINCE_LOGS}T00:00:00Z"
fi

GCLOUD=(gcloud --project="$PROJECT_ID")
if [[ -n "$JSON_DIR" ]]; then
  mkdir -p "$JSON_DIR"
fi

save_json() {
  local name="$1"
  if [[ -n "$JSON_DIR" ]]; then
    cat > "${JSON_DIR}/${name}"
  else
    cat >/dev/null
  fi
}

echo "========================================================================"
echo " VoC Alias-Attach Audit"
echo " Project:  $PROJECT_ID"
echo " Cluster:  $CLUSTER_NAME"
echo " Since:    $SINCE_OPS  (logs >= $SINCE_LOGS)"
echo " Zone:     ${ZONE:-ALL}"
echo "========================================================================"

# -------------------------------------------------------------------------
# 1) Reserved addresses for this cluster
# -------------------------------------------------------------------------
echo ""
echo "[1] Reserved INTERNAL addresses matching name~^${CLUSTER_NAME}"
echo "------------------------------------------------------------------------"

ADDR_JSON="$("${GCLOUD[@]}" compute addresses list \
  --filter="addressType=INTERNAL AND name~^${CLUSTER_NAME}" \
  --format=json)"
echo "$ADDR_JSON" | save_json "addresses-${CLUSTER_NAME}.json"

ADDR_COUNT="$(echo "$ADDR_JSON" | jq 'length')"
if [[ "$ADDR_COUNT" -eq 0 ]]; then
  echo "  [WARN] No addresses found with name prefix '${CLUSTER_NAME}'"
else
  printf "  %-18s %-10s %-55s %s\n" "ADDRESS" "STATUS" "NAME" "USERS"
  echo "$ADDR_JSON" | jq -r '
    sort_by(.address)[] |
    [
      .address,
      .status,
      .name,
      ((.users // []) | map(split("/") | last) | join(",") // "-")
    ] | @tsv
  ' | while IFS=$'\t' read -r addr status name users; do
    printf "  %-18s %-10s %-55s %s\n" "$addr" "$status" "$name" "${users:--}"
  done
fi

# -------------------------------------------------------------------------
# 2) Cluster VMs + alias inventory
# -------------------------------------------------------------------------
echo ""
echo "[2] Cluster VMs (tag=voc-internal AND cluster_name/name~^${CLUSTER_NAME})"
echo "------------------------------------------------------------------------"
echo "  VAST marker: network tag 'voc-internal' (Polaris: on every cluster node)"

# voc-internal is applied to all VoC instance templates (enode/cnode/vms/dnode).
INST_FILTER="(tags.items=voc-internal) AND ((labels.cluster_name=${CLUSTER_NAME}) OR (name~^${CLUSTER_NAME}))"
INST_ARGS=(compute instances list --filter="$INST_FILTER" --format=json)
if [[ -n "$ZONE" ]]; then
  INST_ARGS+=(--zones="$ZONE")
fi
INST_JSON="$("${GCLOUD[@]}" "${INST_ARGS[@]}")"
echo "$INST_JSON" | save_json "instances-${CLUSTER_NAME}.json"

INST_COUNT="$(echo "$INST_JSON" | jq 'length')"
if [[ "$INST_COUNT" -eq 0 ]]; then
  echo "  [WARN] No voc-internal instances for cluster '${CLUSTER_NAME}'"
  SOFT_JSON="$("${GCLOUD[@]}" compute instances list \
    --filter="(labels.cluster_name=${CLUSTER_NAME}) OR (name~^${CLUSTER_NAME})" \
    --format=json 2>/dev/null || echo '[]')"
  SOFT_COUNT="$(echo "$SOFT_JSON" | jq 'length')"
  if [[ "$SOFT_COUNT" -gt 0 ]]; then
    echo "  [INFO] ${SOFT_COUNT} name/label match(es) lack tag voc-internal: not treated as VAST cluster nodes"
  fi
else
  echo "$INST_JSON" | jq -r '
    .[] |
    . as $i |
    ($i.networkInterfaces // [])[] |
    [
      $i.status,
      $i.name,
      ($i.zone | split("/") | last),
      (([$i.labels.cluster_name // "-", $i.labels["voc-cluster-role"] // "-"] | join("/"))),
      (.networkIP // "-"),
      ((.aliasIpRanges // []) | map(.ipCidrRange) | join(";") // "NONE")
    ] | @tsv
  ' | while IFS=$'\t' read -r status name zone labels primary aliases; do
    echo "  ${status}  ${name}  (${labels})"
    echo "    zone=${zone}  primary=${primary}"
    echo "    aliases=${aliases}"
  done
fi

# -------------------------------------------------------------------------
# 3) Diff: reserved addrs not present as primary/alias on any VM
#    3b) Explicit DNS VIP check (often reserved, never attached / never published)
# -------------------------------------------------------------------------
echo ""
echo "[3] Reservation <-> NIC alias gaps"
echo "------------------------------------------------------------------------"

AUDIT_RC_FILE="$(mktemp)"
AUDIT_DETAIL_FILE="$(mktemp)"
AUDIT_REMEDIATE_FILE="$(mktemp)"
OPS_TMP="$(mktemp)"
echo 0 > "$AUDIT_RC_FILE"
: > "$AUDIT_DETAIL_FILE"
: > "$AUDIT_REMEDIATE_FILE"
echo '[]' > "$OPS_TMP"
# shellcheck disable=SC2064
trap 'rm -f "$OPS_TMP" "$AUDIT_RC_FILE" "$AUDIT_DETAIL_FILE" "$AUDIT_REMEDIATE_FILE"' EXIT

export VOC_ADDR_JSON="$ADDR_JSON"
export VOC_INST_JSON="$INST_JSON"
export VOC_CLUSTER="$CLUSTER_NAME"
export VOC_PROJECT="$PROJECT_ID"
export VOC_AUDIT_RC_FILE="$AUDIT_RC_FILE"
export VOC_AUDIT_DETAIL_FILE="$AUDIT_DETAIL_FILE"
export VOC_AUDIT_REMEDIATE_FILE="$AUDIT_REMEDIATE_FILE"

python3 <<'PY'
import json, os

addrs = json.loads(os.environ["VOC_ADDR_JSON"])
insts = json.loads(os.environ["VOC_INST_JSON"])
cluster = os.environ.get("VOC_CLUSTER", "")
project = os.environ.get("VOC_PROJECT", "PROJECT")
rc_file = os.environ["VOC_AUDIT_RC_FILE"]
detail_file = os.environ.get("VOC_AUDIT_DETAIL_FILE", "")
remediate_file = os.environ.get("VOC_AUDIT_REMEDIATE_FILE", "")
exit_rc = 0
# 0=ok, 2=live cluster VIP/alias gaps, 3=orphaned reservations (no live VMs)
detail_lines = []
remediate_lines = []

def emit(line=""):
    """Error facts for [3] (and echoed at top of [6]). No remediation commands."""
    print(line)
    detail_lines.append(line)

def remediate(line=""):
    """Commands / cleanup: printed only in [6]."""
    remediate_lines.append(line)

vm_ips = set()
vm_alias_ips = set()
vms = []
# Instance list is already filtered to tags.items=voc-internal (VAST nodes).
# Treat only RUNNING/STAGING as live so destroy-in-progress (STOPPING) is not.
LIVE_STATUSES = {"RUNNING", "STAGING"}
for i in insts:
    zone = (i.get("zone") or "").split("/")[-1]
    status = i.get("status") or ""
    tags = set((i.get("tags") or {}).get("items") or [])
    for nic in i.get("networkInterfaces") or []:
        aliases = set()
        if nic.get("networkIP"):
            vm_ips.add(nic["networkIP"])
        for ar in nic.get("aliasIpRanges") or []:
            cidr = ar.get("ipCidrRange") or ""
            ip = cidr.split("/")[0]
            if ip:
                vm_alias_ips.add(ip)
                vm_ips.add(ip)
                aliases.add(ip)
        vms.append({
            "name": i.get("name"),
            "zone": zone,
            "status": status,
            "tags": tags,
            "primary": nic.get("networkIP"),
            "aliases": aliases,
            "nic": nic.get("name") or "nic0",
        })

orphans = [
    a for a in addrs
    if a.get("status") == "RESERVED" and not (a.get("users") or [])
]
live_vms = [v for v in vms if v["status"] in LIVE_STATUSES]
live = bool(live_vms)
torn_down_leak = (not live) and bool(orphans)

if vms and not live:
    stopping = sorted({v["name"] for v in vms if v["status"] not in LIVE_STATUSES})
    print(f"  [INFO] {len(vms)} voc-internal VM(s) but none RUNNING/STAGING: treat as not live")
    for n in stopping:
        st = next(v["status"] for v in vms if v["name"] == n)
        print(f"           {n}  status={st}")
    print("")

if torn_down_leak:
    exit_rc = 3
    emit(f"  [FAIL] No live VMs for '{cluster}' but {len(orphans)} RESERVED address(es) remain")
    emit("         Cluster looks deleted; teardown left VIP/node IP reservations.")
    emit("         This is NOT a DNS-VIP attach failure on a live cluster.")
    emit("")
    emit("  Orphaned reservations:")
    for a in sorted(orphans, key=lambda x: x.get("address") or ""):
        emit(f"      [ORPHAN] {a.get('address'):15} {a.get('name')}")
    region = "REGION"
    if orphans:
        r = (orphans[0].get("region") or "")
        if r:
            region = r.split("/")[-1]
        elif orphans[0].get("subnetwork"):
            region = "us-central1"
    remediate("  Cleanup (review first):")
    remediate(f"    gcloud compute addresses list --project={project} --filter='name~^{cluster}' \\")
    remediate("      --format='value(name,region.basename(),status)'")
    remediate("    # then for each RESERVED name:")
    remediate(f"    # gcloud compute addresses delete NAME --region={region} --project={project} --quiet")
else:
    missing = []
    attached_ok = 0
    dns_pending = []  # reserved dns-vip, expected until DNS service enabled
    for a in sorted(addrs, key=lambda x: x.get("address") or ""):
        ip = a.get("address")
        name = a.get("name") or ""
        status = a.get("status")
        users = [u.split("/")[-1] for u in (a.get("users") or [])]
        if ip in vm_ips:
            attached_ok += 1
        elif name.endswith("-dns-vip"):
            dns_pending.append((ip, status, name))
        else:
            missing.append((ip, status, name, users))

    print(f"  addresses={len(addrs)}  on_nic={attached_ok}  MISSING_FROM_NIC={len(missing)}  dns_vip_pending={len(dns_pending)}")
    if missing:
        exit_rc = 2
        emit(f"  [FAIL] {len(missing)} reserved VIP/internal IP(s) NOT on any cluster VM NIC/alias")
        emit("         IPs are allocated in GCP (RESERVED) but never published to the eNode.")
        emit("         Typical cause: incomplete/raced updateNetworkInterface (partial alias set).")
        emit("")
        emit("  Missing addresses:")
        for ip, status, name, users in missing:
            emit(f"      [GAP] {ip:15} {status:8} {name}  users={users or '-'}")
        target = next((v for v in live_vms if "enode" in (v["name"] or "")), None)
        if target is None and live_vms:
            target = live_vms[0]
        if target:
            existing = sorted(target["aliases"])
            gap_ips = [ip for ip, _, _, _ in missing if ip]
            new_aliases = existing[:]
            for ip in gap_ips:
                if ip not in new_aliases:
                    new_aliases.append(ip)
            alias_arg = ";".join(f"{a}/32" for a in new_aliases)
            emit("")
            emit(f"  Target eNode: {target['name']}  zone={target['zone']}  nic={target['nic']}")
            emit(f"  Current aliases on NIC: {';'.join(existing) if existing else '(none)'}")
            remediate("  Remediation (ONE update; include ALL aliases; replace-all):")
            remediate(f"    gcloud compute instances network-interfaces update {target['name']} \\")
            remediate(f"      --zone={target['zone']} --project={project} \\")
            remediate(f"      --network-interface={target['nic']} \\")
            remediate(f"      --aliases='{alias_arg}'")
            remediate("    # Do NOT fan out one-VIP-per-RPC in parallel (Invalid fingerprint).")
    elif addrs and not dns_pending:
        print("  [PASS] All cluster addresses appear on a VM primary or alias")
    elif addrs and not missing:
        print("  [PASS] Non-DNS addresses on NICs; DNS VIP pending is expected (see [3b])")
    else:
        print("  [INFO] No addresses and no instances: nothing to audit")

    if dns_pending:
        for ip, status, name in dns_pending:
            print(f"      [DNS-PENDING] {ip:15} {status:8} {name}  (OK until DNS service enabled)")

    reserved = {a.get("address") for a in addrs}
    orphan_aliases = sorted(vm_alias_ips - reserved)
    if orphan_aliases:
        print("  aliases present without a matching cluster address reservation:")
        for ip in orphan_aliases:
            print(f"      [INFO] {ip}  (on NIC but no <cluster>-* address reservation)")
            if exit_rc == 2:
                detail_lines.append(
                    f"      [INFO] {ip}  (on NIC but no <cluster>-* address reservation)"
                )
# --- Explicit DNS VIP ---
# Polaris: often absent, or reserved and left unattached until DNS service is
# enabled on the cluster. Neither is an audit failure.
print("")
print("[3b] DNS VIP (explicit)")
print("-" * 72)
dns_name = f"{cluster}-dns-vip"
dns = next((a for a in addrs if (a.get("name") or "") == dns_name), None)
if dns is None:
    dns = next((a for a in addrs if (a.get("name") or "").endswith("-dns-vip")), None)

if torn_down_leak:
    if dns:
        print(f"  name:    {dns.get('name')}")
        print(f"  address: {dns.get('address')}")
        print(f"  status:  {dns.get('status')} (orphaned with cluster)")
        print("  [SKIP] DNS VIP lifecycle check: no live VMs (see ORPHAN above)")
    else:
        print(f"  [SKIP] No '{dns_name}' among orphans")
        print("         Primary issue is leaked RESERVED addresses, not DNS.")
elif not live and not addrs:
    print("  [SKIP] No cluster resources found")
elif not live:
    print("  [SKIP] No live VMs: DNS VIP check not applicable")
elif dns is None:
    print(f"  [OK] No address named '{dns_name}'")
    print("       Some Polaris deploys omit dns-vip until/unless DNS is used.")
else:
    ip = dns.get("address")
    status = dns.get("status")
    name = dns.get("name")
    users = [u.split("/")[-1] for u in (dns.get("users") or [])]
    holders = [v for v in vms if ip in v["aliases"] or v["primary"] == ip]
    print(f"  name:    {name}")
    print(f"  address: {ip}")
    print(f"  status:  {status}")
    print(f"  users:   {users or '-'}")
    if holders:
        for v in holders:
            where = "ALIAS" if ip in v["aliases"] else "PRIMARY"
            print(f"  [OK] Attached as {where} on {v['name']} ({v['zone']})")
            print("       DNS service has likely been enabled (VIP is on a NIC).")
    else:
        print("  [OK] Reserved but not attached (Polaris default until DNS is enabled)")
        print("       Enable DNS on the cluster to have install attach this VIP;")
        print("       not an alias-attach race / teardown failure.")

with open(rc_file, "w") as f:
    f.write(str(exit_rc))
if detail_file and detail_lines:
    with open(detail_file, "w") as f:
        f.write("\n".join(detail_lines) + "\n")
if remediate_file and remediate_lines:
    with open(remediate_file, "w") as f:
        f.write("\n".join(remediate_lines) + "\n")
PY

# -------------------------------------------------------------------------
# 4) Zone updateNetworkInterface operations
# -------------------------------------------------------------------------
echo ""
echo "[4] Zone ops: updateNetworkInterface for ${CLUSTER_NAME} (since ${SINCE_OPS})"
echo "------------------------------------------------------------------------"

if [[ -n "$ZONE" ]]; then
  ZONE_LIST="$ZONE"
else
  ZONE_LIST="$(echo "$INST_JSON" | jq -r '.[].zone | split("/") | last' | sort -u | tr '\n' ' ')"
  if [[ -z "${ZONE_LIST// /}" ]]; then
    ZONE_LIST="$("${GCLOUD[@]}" compute instances list \
      --filter="(tags.items=voc-internal) AND (name~^${CLUSTER_NAME})" \
      --format='value(zone.basename())' 2>/dev/null | sort -u | tr '\n' ' ')"
  fi
fi

for z in $ZONE_LIST; do
  [[ -z "$z" ]] && continue
  echo "  zone=${z}"
  ZOPS="$("${GCLOUD[@]}" compute operations list \
    --zones="$z" \
    --filter="targetLink~${CLUSTER_NAME} AND insertTime>${SINCE_OPS}" \
    --format=json 2>/dev/null || echo '[]')"
  jq -s '.[0] + .[1]' "$OPS_TMP" <(echo "$ZOPS") > "${OPS_TMP}.new"
  mv "${OPS_TMP}.new" "$OPS_TMP"

  echo "$ZOPS" | jq -r '
    [.[] | select(.operationType == "updateNetworkInterface")] |
    if length == 0 then
      "    (no updateNetworkInterface ops)"
    else
      .[] |
      "    \(.insertTime)  \(if .httpErrorStatusCode then "ERR=\(.httpErrorStatusCode) \(.httpErrorMessage // "")" else "OK" end)  \(.user // "-")  target=\((.targetLink // "") | split("/") | last)  \(.name)"
    end
  '
done

OPS_ALL="$(cat "$OPS_TMP")"
echo "$OPS_ALL" | save_json "zone-ops-${CLUSTER_NAME}.json"

FAIL_COUNT="$(echo "$OPS_ALL" | jq '[.[] | select(.operationType=="updateNetworkInterface" and .httpErrorStatusCode != null)] | length')"
echo ""
echo "  updateNetworkInterface failures: ${FAIL_COUNT}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "$OPS_ALL" | jq -c '
    .[] | select(.operationType=="updateNetworkInterface" and .httpErrorStatusCode != null)
  ' | while read -r row; do
    opname="$(echo "$row" | jq -r '.name')"
    z="$(echo "$row" | jq -r '.targetLink | split("/zones/")[1] | split("/")[0]')"
    echo ""
    echo "  --- failure detail ---"
    echo "  op=${opname}  zone=${z}"
    DESC="$("${GCLOUD[@]}" compute operations describe "$opname" --zone="$z" --format=json)"
    if [[ -n "$JSON_DIR" ]]; then
      echo "$DESC" > "${JSON_DIR}/op-${opname}.json"
    fi
    # Expand the actual API error (Invalid fingerprint, etc.)
    echo "$DESC" | python3 -c "
import json, sys
op = json.load(sys.stdin)
print('  time:   {}'.format(op.get('insertTime')))
print('  user:   {}'.format(op.get('user')))
http = '{} {}'.format(op.get('httpErrorStatusCode') or '', op.get('httpErrorMessage') or '').strip()
print('  http:   {}'.format(http))
print('  target: {}'.format((op.get('targetLink') or '').split('/')[-1]))
errs = ((op.get('error') or {}).get('errors') or [])
if errs:
    print('  errors:')
    for e in errs:
        code = e.get('code') or ''
        msg = e.get('message') or ''
        print('    [{}] {}'.format(code, msg) if code else '    {}'.format(msg))
elif op.get('statusMessage'):
    print('  statusMessage: {}'.format(op.get('statusMessage')))
else:
    print('  (no error.errors[] on operation; check audit logs in [5])')
"
  done
fi

# -------------------------------------------------------------------------
# 5) Cloud Audit Logs (optional)
# -------------------------------------------------------------------------
if [[ "$DO_LOGS" -eq 1 ]]; then
  echo ""
  echo "[5] Cloud Audit Logs: instances.updateNetworkInterface (since ${SINCE_LOGS})"
  echo "------------------------------------------------------------------------"
  echo "  COMMAND: gcloud logging read \\"
  echo "    'protoPayload.methodName=\"v1.compute.instances.updateNetworkInterface\""
  echo "     AND protoPayload.resourceName:\"${CLUSTER_NAME}-enode\""
  echo "     AND timestamp>=\"${SINCE_LOGS}\"' \\"
  echo "    --project=${PROJECT_ID} --format=json --limit=100"

  LOG_JSON="$("${GCLOUD[@]}" logging read \
    "protoPayload.methodName=\"v1.compute.instances.updateNetworkInterface\" AND protoPayload.resourceName:\"${CLUSTER_NAME}-enode\" AND timestamp>=\"${SINCE_LOGS}\"" \
    --format=json \
    --limit=100 2>/dev/null || echo '[]')"
  echo "$LOG_JSON" | save_json "audit-updateNetworkInterface-${CLUSTER_NAME}.json"

  LOG_COUNT="$(echo "$LOG_JSON" | jq 'length')"
  echo "  entries=${LOG_COUNT}"

  if [[ "$LOG_COUNT" -gt 0 ]]; then
    export VOC_LOG_JSON="$LOG_JSON"
    export VOC_ADDR_JSON="$ADDR_JSON"
    python3 <<'PY'
import json, os

logs = json.loads(os.environ["VOC_LOG_JSON"])
addrs = json.loads(os.environ.get("VOC_ADDR_JSON") or "[]")
# Expected VIP/internal IPs (exclude dns-vip; attach is optional)
expected = set()
for a in addrs:
    name = a.get("name") or ""
    ip = a.get("address")
    if not ip:
        continue
    if name.endswith("-dns-vip"):
        continue
    # node primaries are IN_USE as users on instances; still expect aliases for *-vip / *-internal-*
    if ("-vip" in name) or ("-internal-" in name):
        expected.add(ip)

def aliases(req):
    """Request shapes vary: aliasIpRanges on request OR under networkInterface object."""
    if not isinstance(req, dict):
        return []
    ranges = req.get("aliasIpRanges")
    if isinstance(ranges, list):
        return [a.get("ipCidrRange") for a in ranges if isinstance(a, dict)]
    nic = req.get("networkInterface")
    if isinstance(nic, dict):
        return [a.get("ipCidrRange") for a in (nic.get("aliasIpRanges") or []) if isinstance(a, dict)]
    return []

def fingerprint(req):
    if not isinstance(req, dict):
        return None
    if req.get("fingerprint"):
        return "(present)"
    nic = req.get("networkInterface")
    if isinstance(nic, dict) and nic.get("fingerprint"):
        return "(present)"
    return None

def expand_status(st):
    """Pull userVisibleReason / nested messages out of status.details."""
    msgs = []
    top = st.get("message")
    if top:
        msgs.append(str(top))

    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k in ("userVisibleReason", "errorMessage", "httpErrorMessage", "description") and isinstance(v, str) and v:
                    msgs.append(v)
                else:
                    walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(st.get("details") or [])
    # de-dupe preserving order
    out = []
    for m in msgs:
        if m not in out:
            out.append(m)
    return out

print(f"  {'TIMESTAMP(UTC)':<28} {'':<4} {'INSTANCE':<42} ALIASES")
print("  " + "-" * 120)
err_n = 0
partial_n = 0
for e in sorted(logs, key=lambda x: x.get("timestamp") or ""):
    pp = e.get("protoPayload") or {}
    st = pp.get("status") or {}
    code = st.get("code", 0) or 0
    inst = (pp.get("resourceName") or "").split("/")[-1]
    req = pp.get("request") or {}
    al = [x for x in aliases(req) if x]
    al_s = ";".join(al) if al else "(no alias payload)"
    principal = ((pp.get("authenticationInfo") or {}).get("principalEmail") or "-")
    fp = fingerprint(req)
    if code:
        flag = "ERR"
        err_n += 1
    else:
        flag = "ok "
    print(f"  {e.get('timestamp',''):<28} {flag} {inst:<42} {al_s}")
    print(f"      principal={principal}  fingerprint={fp or '(none/omitted)'}")
    if code:
        for m in expand_status(st):
            print(f"      ERROR: {m}")
    elif al and expected:
        attached = {cidr.split("/")[0] for cidr in al}
        missing = sorted(expected - attached)
        if missing:
            partial_n += 1
            print(f"      PARTIAL attach: missing {len(missing)} expected VIP(s): {', '.join(missing)}")

print("")
print(f"  summary: entries={len(logs)}  ERR={err_n}  PARTIAL_ok_payloads={partial_n}")
if err_n:
    print("  ERR rows expand status.message + status.details.*.userVisibleReason (e.g. Invalid fingerprint).")
if partial_n:
    print("  PARTIAL = RPC succeeded but alias list did not include all reserved VIP/internal IPs.")

# --- Forensics: incremental attach + near-concurrent races ---
# Only consider rows that actually carried an alias payload (drop empty echo/completion rows).
events = []
for e in sorted(logs, key=lambda x: x.get("timestamp") or ""):
    pp = e.get("protoPayload") or {}
    st = pp.get("status") or {}
    code = st.get("code", 0) or 0
    req = pp.get("request") or {}
    al = [x for x in aliases(req) if x]
    if not al and not code:
        continue
    attached = {cidr.split("/")[0] for cidr in al}
    events.append({
        "ts": e.get("timestamp") or "",
        "code": code,
        "al": al,
        "ips": attached,
        "errs": expand_status(st) if code else [],
    })

if len(events) >= 1:
    print("")
    print("  --- forensics (alias-bearing updates only) ---")
    prev_ips = set()
    for i, ev in enumerate(events):
        added = sorted(ev["ips"] - prev_ips) if prev_ips else sorted(ev["ips"])
        removed = sorted(prev_ips - ev["ips"]) if prev_ips else []
        extra = sorted(ev["ips"] - expected) if expected else []
        miss = sorted(expected - ev["ips"]) if expected else []
        flag = "ERR" if ev["code"] else "ok "
        print(f"  {ev['ts']}  {flag}  n={len(ev['ips'])}  aliases={';'.join(ev['al']) if ev['al'] else '(none)'}")
        if added:
            print(f"      +added:   {', '.join(added)}")
        if removed:
            print(f"      -removed: {', '.join(removed)}  (replace-all dropped these)")
        if extra:
            print(f"      EXTRA:    {', '.join(extra)}  (on NIC payload but NOT a <cluster> VIP/internal reservation)")
        if miss and not ev["code"]:
            print(f"      still missing reserved: {', '.join(miss)}")
        if ev["errs"]:
            for m in ev["errs"]:
                print(f"      ERROR: {m}")
        if not ev["code"]:
            prev_ips = set(ev["ips"])

    # Near-concurrent pairs (< 500ms) -> fingerprint race signature
    def parse_ts(ts):
        # 2026-09-24T23:34:10.739783Z
        try:
            from datetime import datetime
            return datetime.strptime(ts[:26].ljust(26, "0"), "%Y-%m-%dT%H:%M:%S.%f")
        except Exception:
            return None

    races = []
    for i in range(len(events) - 1):
        a, b = events[i], events[i + 1]
        ta, tb = parse_ts(a["ts"]), parse_ts(b["ts"])
        if ta is None or tb is None:
            continue
        delta_ms = (tb - ta).total_seconds() * 1000.0
        if delta_ms < 500 and a["ips"] and b["ips"] and a["ips"] != b["ips"]:
            races.append((delta_ms, a, b))

    if races:
        print("")
        print(f"  RACE WINDOWS: {len(races)} pair(s) of alias updates <500ms apart with DIFFERENT alias sets")
        print("  (classic Invalid fingerprint / last-writer-wins when installer fans out one-VIP-per-RPC)")
        for delta_ms, a, b in races:
            print(f"    Δ={delta_ms:.0f}ms")
            print(f"      A: {a['ts']}  {';'.join(a['al'])}")
            print(f"      B: {b['ts']}  {';'.join(b['al'])}")
    else:
        # Still flag strictly incremental growth (serial one-VIP-at-a-time)
        sizes = [len(ev["ips"]) for ev in events if not ev["code"] and ev["ips"]]
        if len(sizes) >= 3 and all(sizes[i] <= sizes[i + 1] for i in range(len(sizes) - 1)) and sizes[-1] > sizes[0]:
            print("")
            print("  PATTERN: serial incremental alias growth (n={})".format(
                " -> ".join(str(s) for s in sizes)
            ))
            print("  (each successful PATCH carries a growing/partial set; see forensics doc)")
PY
  else
    echo "  (no audit entries; check Logging API perms or widen --since)"
  fi

  # -----------------------------------------------------------------------
  # 5b) On-node cloud_cli logs (ops-agent -> Cloud Logging)
  #     Evidence only: assign_ip / fingerprint lines if present
  # -----------------------------------------------------------------------
  echo ""
  echo "[5b] cloud_cli logs (ops-agent logName=cloud-cli, since ${SINCE_LOGS})"
  echo "------------------------------------------------------------------------"
  CLUSTER_ID="$(echo "$INST_JSON" | jq -r '[.[] | .labels.cluster_id // empty] | first // empty')"
  if [[ -z "$CLUSTER_ID" ]]; then
    echo "  [SKIP] No labels.cluster_id on matched instances: cannot filter cloud_cli by cluster"
  else
    echo "  cluster_id=${CLUSTER_ID}"
    echo "  COMMAND: gcloud logging read \\"
    echo "    'resource.type=\"gce_instance\" AND labels.cluster_id=\"${CLUSTER_ID}\""
    echo "     AND logName=\"projects/${PROJECT_ID}/logs/cloud-cli\""
    echo "     AND timestamp>=\"${SINCE_LOGS}\"' \\"
    echo "    --project=${PROJECT_ID} --format=json --limit=200"
    CLI_JSON="$("${GCLOUD[@]}" logging read \
      "resource.type=\"gce_instance\" AND labels.cluster_id=\"${CLUSTER_ID}\" AND logName=\"projects/${PROJECT_ID}/logs/cloud-cli\" AND timestamp>=\"${SINCE_LOGS}\"" \
      --format=json \
      --limit=200 2>/dev/null || echo '[]')"
    echo "$CLI_JSON" | save_json "cloud-cli-${CLUSTER_NAME}.json"
    export VOC_CLI_JSON="$CLI_JSON"
    python3 <<'PY'
import json, os, re
from collections import defaultdict

raw = os.environ.get("VOC_CLI_JSON") or "[]"
try:
    logs = json.loads(raw)
except Exception:
    logs = []

def msg(e):
    jp = e.get("jsonPayload") or {}
    t = e.get("textPayload")
    if t:
        return str(t)
    if isinstance(jp, dict) and jp.get("message"):
        return str(jp["message"])
    return ""

# Keep lines that look like VIP attach / fingerprint handling
keep_re = re.compile(
    r"assign_ip|_assign_ips|_update_network_interface|fingerprint|PreconditionFailed|"
    r"failed to configure interface|succefully assigned|successfully assigned|dummy",
    re.I,
)
pid_re = re.compile(r"\(P(\d+)\)")
fp_re = re.compile(r"fingerprint='([^']+)'")
ip_assign_re = re.compile(r"assign_ip,\s*args:\s*ip=\(([^)]+)\)")
ip_ok_re = re.compile(r"assigned ips=\(([^)]+)\)", re.I)

rows = []
for e in logs:
    m = " ".join(msg(e).split())
    if not m or not keep_re.search(m):
        continue
    rows.append((e.get("timestamp") or "", m))

rows.sort(key=lambda x: x[0])
print(f"  cloud_cli entries scanned={len(logs)}  attach-related lines={len(rows)}")
if not rows:
    print("  (no assign_ip / fingerprint lines in window; widen --since or check ops-agent)")
else:
    print(f"  {'TIMESTAMP(UTC)':<28} cloud_cli")
    print("  " + "-" * 100)
    for ts, m in rows[:80]:
        print(f"  {ts:<28} {m[:160]}")
        if len(m) > 160:
            print(f"  {'':<28} ...{m[160:300]}")
    if len(rows) > 80:
        print(f"  ... truncated {len(rows) - 80} more lines (see --json-dir)")

    # Concurrent assign_ip by PID within 500ms (observation aid)
    events = []
    for ts, m in rows:
        if "assign_ip, args:" not in m and "assigning ip" not in m.lower():
            continue
        pid_m = pid_re.search(m)
        ip_m = ip_assign_re.search(m)
        events.append({
            "ts": ts,
            "pid": pid_m.group(1) if pid_m else "?",
            "ip": (ip_m.group(1).strip().strip("'\",") if ip_m else "?"),
            "line": m,
        })

    def parse_ts(ts):
        try:
            from datetime import datetime
            return datetime.strptime(ts[:26].ljust(26, "0"), "%Y-%m-%dT%H:%M:%S.%f")
        except Exception:
            return None

    pairs = []
    for i in range(len(events)):
        for j in range(i + 1, len(events)):
            a, b = events[i], events[j]
            if a["pid"] == b["pid"] and a["pid"] != "?":
                continue
            ta, tb = parse_ts(a["ts"]), parse_ts(b["ts"])
            if ta is None or tb is None:
                continue
            delta = abs((tb - ta).total_seconds() * 1000.0)
            if delta < 500:
                pairs.append((delta, a, b))

    fp_miss = [m for _, m in rows if re.search(r"fingerprint mismatch|PreconditionFailed|Invalid fingerprint", m, re.I)]
    print("")
    print(f"  observation: assign_ip lines={len(events)}  near-concurrent different-PID pairs(<500ms)={len(pairs)}  fingerprint-mismatch lines={len(fp_miss)}")
    for delta, a, b in pairs[:5]:
        print(f"    Δ={delta:.0f}ms  P{a['pid']} ip={a['ip']}  ||  P{b['pid']} ip={b['ip']}")
    for m in fp_miss[:5]:
        print(f"    mismatch: {m[:200]}")
    print("  (Interpretation left to cloud_cli / VMS owners; see")
    print("   vastcloud/VastCloud-GCP-VIP-Alias-Attach-Forensics.md in sre-runbooks)")
PY
  fi
else
  echo ""
  echo "[5] Cloud Audit Logs skipped (--no-logs)"
  echo ""
  echo "[5b] cloud_cli logs skipped (--no-logs)"
fi

# -------------------------------------------------------------------------
# 6) Remediation: commands only here (not mixed into [3]/[5])
# -------------------------------------------------------------------------
echo ""
echo "[6] Remediation"
echo "------------------------------------------------------------------------"

AUDIT_RC="$(cat "$AUDIT_RC_FILE" 2>/dev/null || echo 0)"
case "$AUDIT_RC" in
  2)
    if [[ -s "$AUDIT_DETAIL_FILE" ]]; then
      echo "  --- error summary ---"
      cat "$AUDIT_DETAIL_FILE"
      echo ""
    fi
    if [[ -s "$AUDIT_REMEDIATE_FILE" ]]; then
      cat "$AUDIT_REMEDIATE_FILE"
      echo ""
    fi
    echo "  Inspect:"
    echo "    gcloud compute instances list --project=${PROJECT_ID} \\"
    echo "      --filter='(tags.items=voc-internal) AND (labels.cluster_name=${CLUSTER_NAME})' \\"
    echo "      --format='table(name,zone.basename(),status,networkInterfaces[0].networkIP,networkInterfaces[0].aliasIpRanges[].ipCidrRange.list())'"
    echo "========================================================================"
    echo "RESULT: VIP/alias GAP on LIVE cluster (exit 2)"
    exit 2
    ;;
  3)
    if [[ -s "$AUDIT_DETAIL_FILE" ]]; then
      echo "  --- error summary ---"
      cat "$AUDIT_DETAIL_FILE"
      echo ""
    fi
    if [[ -s "$AUDIT_REMEDIATE_FILE" ]]; then
      cat "$AUDIT_REMEDIATE_FILE"
      echo ""
    fi
    echo "========================================================================"
    echo "RESULT: ORPHANED reservations (cluster gone, IPs leaked) (exit 3)"
    exit 3
    ;;
  0)
    echo "  No remediation needed."
    echo "  Exit codes: 0=ok  2=live VIP/alias gaps  3=orphan leak after teardown"
    echo "========================================================================"
    echo "RESULT: PASS"
    exit 0
    ;;
  *)
    echo "  Unexpected status (exit ${AUDIT_RC}). Re-check [3]/[3b]."
    echo "========================================================================"
    echo "RESULT: FAILED (exit ${AUDIT_RC})"
    exit "$AUDIT_RC"
    ;;
esac
