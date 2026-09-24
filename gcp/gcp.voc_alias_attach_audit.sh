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
#     partial alias lists + stale fingerprint → Invalid fingerprint /
#     missing aliases even though addresses are RESERVED.
#
# NOTES
#     Requires: gcloud, jq, python3
#     Author: Karl Vietmeier
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
    echo "  [INFO] ${SOFT_COUNT} name/label match(es) lack tag voc-internal — not treated as VAST cluster nodes"
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
echo "[3] Reservation ↔ NIC alias gaps"
echo "------------------------------------------------------------------------"

AUDIT_RC_FILE="$(mktemp)"
AUDIT_DETAIL_FILE="$(mktemp)"
OPS_TMP="$(mktemp)"
echo 0 > "$AUDIT_RC_FILE"
: > "$AUDIT_DETAIL_FILE"
echo '[]' > "$OPS_TMP"
# shellcheck disable=SC2064
trap 'rm -f "$OPS_TMP" "$AUDIT_RC_FILE" "$AUDIT_DETAIL_FILE"' EXIT

export VOC_ADDR_JSON="$ADDR_JSON"
export VOC_INST_JSON="$INST_JSON"
export VOC_CLUSTER="$CLUSTER_NAME"
export VOC_PROJECT="$PROJECT_ID"
export VOC_AUDIT_RC_FILE="$AUDIT_RC_FILE"
export VOC_AUDIT_DETAIL_FILE="$AUDIT_DETAIL_FILE"

python3 <<'PY'
import json, os

addrs = json.loads(os.environ["VOC_ADDR_JSON"])
insts = json.loads(os.environ["VOC_INST_JSON"])
cluster = os.environ.get("VOC_CLUSTER", "")
project = os.environ.get("VOC_PROJECT", "PROJECT")
rc_file = os.environ["VOC_AUDIT_RC_FILE"]
detail_file = os.environ.get("VOC_AUDIT_DETAIL_FILE", "")
exit_rc = 0
# 0=ok, 2=live cluster VIP/alias gaps, 3=orphaned reservations (no live VMs)
detail_lines = []

def emit(line=""):
    print(line)
    detail_lines.append(line)

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
    print(f"  [INFO] {len(vms)} voc-internal VM(s) but none RUNNING/STAGING — treat as not live")
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
    emit("")
    # Guess region from first address
    region = "REGION"
    if orphans:
        r = (orphans[0].get("region") or "")
        if r:
            region = r.split("/")[-1]
        elif orphans[0].get("subnetwork"):
            # fallback hint
            region = "us-central1"
    emit("  Cleanup (review first):")
    emit(f"    gcloud compute addresses list --project={project} --filter='name~^{cluster}' \\")
    emit("      --format='value(name,region.basename(),status)'")
    emit(f"    # then for each RESERVED name:")
    emit(f"    # gcloud compute addresses delete NAME --region={region} --project={project} --quiet")
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
            emit("  Remediation (ONE update; include ALL aliases — replace-all):")
            emit(f"    gcloud compute instances network-interfaces update {target['name']} \\")
            emit(f"      --zone={target['zone']} --project={project} \\")
            emit(f"      --network-interface={target['nic']} \\")
            emit(f"      --aliases='{alias_arg}'")
            emit("    # Do NOT fan out one-VIP-per-RPC in parallel (Invalid fingerprint).")
    elif addrs and not dns_pending:
        print("  [PASS] All cluster addresses appear on a VM primary or alias")
    elif addrs and not missing:
        print("  [PASS] Non-DNS addresses on NICs; DNS VIP pending is expected (see [3b])")
    else:
        print("  [INFO] No addresses and no instances — nothing to audit")

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
        print("  [SKIP] DNS VIP lifecycle check — no live VMs (see ORPHAN above)")
    else:
        print(f"  [SKIP] No '{dns_name}' among orphans")
        print("         Primary issue is leaked RESERVED addresses, not DNS.")
elif not live and not addrs:
    print("  [SKIP] No cluster resources found")
elif not live:
    print("  [SKIP] No live VMs — DNS VIP check not applicable")
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
    echo "  COMMAND: gcloud compute operations describe ${opname} --zone=${z} --project=${PROJECT_ID}"
    DESC="$("${GCLOUD[@]}" compute operations describe "$opname" --zone="$z" --format=json)"
    if [[ -n "$JSON_DIR" ]]; then
      echo "$DESC" > "${JSON_DIR}/op-${opname}.json"
    fi
    echo "$DESC" | jq '{name, insertTime, user, httpErrorStatusCode, httpErrorMessage, error, targetLink}'
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
    python3 <<'PY'
import json, os
logs = json.loads(os.environ["VOC_LOG_JSON"])

def aliases(req):
    if not isinstance(req, dict):
        return []
    nic = req.get("networkInterface")
    if isinstance(nic, dict):
        return [a.get("ipCidrRange") for a in (nic.get("aliasIpRanges") or [])]
    return [a.get("ipCidrRange") for a in (req.get("aliasIpRanges") or [])]

print(f"  {'TIMESTAMP(UTC)':<28} {'':<4} {'INSTANCE':<42} ALIASES / MSG")
print("  " + "-" * 120)
for e in sorted(logs, key=lambda x: x.get("timestamp") or ""):
    pp = e.get("protoPayload") or {}
    st = pp.get("status") or {}
    code = st.get("code", 0) or 0
    msg = st.get("message") or "OK"
    inst = (pp.get("resourceName") or "").split("/")[-1]
    al = aliases(pp.get("request") or {})
    al_s = ";".join(x for x in al if x) if al else "(no alias payload)"
    flag = "ERR" if code else "ok "
    print(f"  {e.get('timestamp',''):<28} {flag} {inst:<42} {al_s}")
    if code:
        print(f"      -> {msg}")
PY
  else
    echo "  (no audit entries — check Logging API perms or widen --since)"
  fi
else
  echo ""
  echo "[5] Cloud Audit Logs skipped (--no-logs)"
fi

# -------------------------------------------------------------------------
# 6) Remediation — only for the actual verdict
# -------------------------------------------------------------------------
echo ""
echo "[6] Remediation"
echo "------------------------------------------------------------------------"

AUDIT_RC="$(cat "$AUDIT_RC_FILE" 2>/dev/null || echo 0)"
case "$AUDIT_RC" in
  2)
    if [[ -s "$AUDIT_DETAIL_FILE" ]]; then
      cat "$AUDIT_DETAIL_FILE"
      echo ""
    fi
    echo "  Do NOT attach one VIP per parallel RPC (Invalid fingerprint)."
    echo ""
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
      cat "$AUDIT_DETAIL_FILE"
      echo ""
    fi
    echo "========================================================================"
    echo "RESULT: ORPHANED reservations (cluster gone, IPs leaked) (exit 3)"
    exit 3
    ;;
  0)
    echo "  DNS VIP: absent or reserved-until-DNS-enabled is normal Polaris behavior."
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
