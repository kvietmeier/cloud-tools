# VoC on GCP — VIP / alias attach observations (forensics)

**Audience:** Polaris / VoC / cloud_cli owners  
**From:** Solutions / field GCP diagnostics  
**Status:** Observations and evidence only — not a design proposal  
**Date:** 2026-09-24  
**Clusters examined:** `karlv-foobar-01`, `karlv-foobar-02` (project `vast-on-cloud`, zone `us-central1-a`)  
**Build seen in VMS deploy checkpoint:** `release-5-4-2-4K-2255166` / image `polaris-voc-5-4-2-2255166`  
**Field context:** Same fingerprint / partial-alias class of symptoms has been seen more than once in lab, including on larger (~8-node) clusters; this write-up uses the foobar pair because the cloud_cli + Compute audit trail is complete and recent.

This note summarizes what we can see from **GCP Compute operations**, **Cloud Audit Logs**, and **on-node logs shipped via ops-agent** (configured in Polaris `cloud-init.yaml`). We are sharing it so engineering can validate or correct our reading of the install path.

---

## 1. Symptom we were asked to look at

On live VoC clusters, some reserved VIP / internal addresses remain `RESERVED` (or are only intermittently `IN_USE`) while the eNode NIC `aliasIpRanges` do not contain the full set of reserved VIP/internal IPs that appear in TF / `voc_config`.

DNS VIP reserved-but-unattached appears consistent with “DNS not enabled yet” and is called out separately; this note focuses on **mgmt / mgmt-inner / replication (internal-*)** addresses.

Repro aid (field script, optional):

```bash
./gcp.voc_alias_attach_audit.sh <CLUSTER_NAME> -p <PROJECT>
```

---

## 2. How we pulled evidence (log map)

Polaris GCP `cloud-init.yaml` configures Google Cloud Ops Agent receivers. Those show up in Cloud Logging as `logName` values such as:

| Ops-agent receiver | On-disk path | Cloud Logging `logName` (suffix) |
|--------------------|--------------|----------------------------------|
| `cloud-cli` | `/vast/log/cloud_cli.log` | `.../logs/cloud-cli` |
| `vms-workers` | `/vast/vman/vms/log/workers.log` | `.../logs/vms-workers` |
| `polaris-agent` | `/var/log/polaris-agent/polaris-agent.log` | `.../logs/polaris-agent` |
| `configure-cloud-resources` | `/var/log/configure_cloud_resources.log` | (little/no VIP-attach traffic on these deploys) |

Useful filter:

```text
resource.type="gce_instance"
labels.cluster_id="<cluster_id from instance labels>"
```

Also used:

- `gcloud compute addresses list` (reservation vs `IN_USE`)
- `gcloud compute operations list` / `describe` (`updateNetworkInterface`)
- Cloud Audit Logs: `v1.compute.instances.updateNetworkInterface`

---

## 3. Observations (factual)

### 3.1 Terraform places a “dummy” alias `/32` on the instance template

In `polaris/gcp/main.tf` (enode / cnode / vms templates), NIC config includes:

```hcl
# release alias ip via python wouldn't work if there wouldn't be another ip.
# [related issue in google](https://github.com/googleapis/google-cloud-python/issues/11931)
# So creating an extra ip which will act a dummy and wouldn't be deleted
alias_ip_range {
  ip_cidr_range = "/32"
}
```

On the examined VMs, an address that is **not** among the named `<cluster>-mgmt-vip` / `-mgmt-inner-vip` / `-internal-*` / `-dns-vip` reservations appears on `nic0` aliases (examples: `10.120.0.228`, `10.120.0.241`). That is consistent with GCP allocating a concrete `/32` for the template placeholder. Field audits previously labeled these as “EXTRA”; they appear to be the intentional dummy, not an orphan reservation.

### 3.2 `cloud_cli` assigns VIP aliases one IP at a time

From `logName=cloud-cli` on `karlv-foobar-01` / `02`, the install path logs:

- `cloud_cli: assign_ip, args: ip=(...<single ip>...,)`
- `_assign_ips(alias_ips=[...])`
- `_update_network_interface(..., alias_ip_ranges=[...], fingerprint=...)`

Each successful assign reports `succefully assigned ips=(...<that one ip>...,)`.

When the update payload is visible in Cloud Audit Logs, the alias list typically includes the **dummy** address plus a **subset** of reserved VIPs — not always the full reserved set.

### 3.3 Concurrent `assign_ip` processes share a fingerprint

**`karlv-foobar-01`** (local times ~16:34 / UTC ~23:34):

| PID (from cloud_cli) | Action | Notes |
|----------------------|--------|--------|
| `P4511` | `assign_ip('10.120.0.225')` | Starts `_update_network_interface` with `fingerprint='aSoHoye3e7s='` |
| `P5342` | `assign_ip('10.120.0.224')` | Starts `_update_network_interface` with **the same** `fingerprint='aSoHoye3e7s='` ~100ms later |

Compute reports `updateNetworkInterface` **HTTP 400 / `INVALID_USAGE: Invalid fingerprint.`** in the same window. Cloud Audit Logs show two alias-bearing PATCHes **113ms** apart with **different** alias sets (classic replace-all last-writer-wins shape).

**`karlv-foobar-02`** (cloud_cli, explicit):

```text
failed to configure interface due to fingerprint mismatch
retying, execpted: PreconditionFailed(... updateNetworkInterface ... Invalid fingerprint.',) - 412
```

(Retry then proceeds with a newer fingerprint.)

### 3.4 Replace-all subsets can drop a VIP that was attached earlier

Example sequence on `karlv-foobar-01` (Cloud Audit + cloud_cli):

1. Assign **mgmt-vip** `10.120.0.202` — payload includes dummy `.228` + `.202`; cloud_cli logs success for `.202`.
2. Later assign **mgmt-inner** `10.120.0.201` — payload is dummy `.228` + `.201` (**.202 no longer in the PATCH list**).
3. Later parallel assigns for replication internals race as in §3.3.

So the GCP API behavior matches “each PATCH supplies the full desired alias list”; callers that send a subset will remove previously attached aliases that are omitted.

### 3.5 Polaris agent vs VMS vs cloud_cli roles (what we saw)

| Component | Around VIP attach window |
|-----------|---------------------------|
| `polaris-agent` | Heartbeats, `deployment_sync`, `vm_inventory_sync` — no `updateNetworkInterface` / `assign_ip` lines in the samples we pulled |
| `vms-workers` | Cluster deploy checkpoints (`IMAGES_SYNC`, `POST_ACTIVATION_OBJECTS_CREATION`), `poll_vip_pools`, view creation; VIP *pool* activity |
| `cloud-cli` | Actual GCP `updateNetworkInterface` / `assign_ip` calls |
| syslog | e.g. `Removing dummy local route to inner VIP` near inner-VIP handling |

We did **not** attempt to map VMS task graphs to `cloud_cli` invocations beyond timestamps; that mapping is better done by owners of that codepath.

### 3.6 Cluster context on these deploys

From eNode `voc_config` / labels (foobar-01):

- `HA_ENABLED=false`, single eNode role on the examined instance  
- `MGMT_VIP` / `MGMT_INNER_VIP` / `REPLICATION_VIPS` / `DNS_VIP` populated  
- `NODES_COUNT=1` (plus platform containers on the same node as seen in deploy checkpoint data)

MIG `patchPerInstanceConfigs` / `applyUpdatesToInstances` also occur during install; on foobar-01 the fingerprint **400** we inspected was attributed to the **cluster SA** on `updateNetworkInterface`, not to the MIG operation type, in the ops we described.

---

## 4. Evidence pointers (replay)

### 4.1 cloud_cli (cluster_id filter)

```bash
# Example for karlv-foobar-01
CID=8ec20b85-2d27-594e-8dec-1b5a0ce0c641

gcloud logging read \
  "resource.type=\"gce_instance\" AND labels.cluster_id=\"${CID}\" AND logName=\"projects/vast-on-cloud/logs/cloud-cli\" AND timestamp>=\"2026-09-24T22:30:00Z\"" \
  --project=vast-on-cloud --format=json --limit=200
```

Search the messages for: `assign_ip`, `_update_network_interface`, `fingerprint`, `fingerprint mismatch`, `PreconditionFailed`.

### 4.2 Compute operation (fingerprint 400)

Example (foobar-01):

```text
operation-1790292850801-65c43096a7a69-c9b0a8a4-2c0ad771
httpErrorStatusCode=400
error.errors[].code=INVALID_USAGE
error.errors[].message=Invalid fingerprint.
user=karlv-foobar-01-sa@vast-on-cloud.iam.gserviceaccount.com
```

### 4.3 Cloud Audit Logs

```bash
gcloud logging read \
  'protoPayload.methodName="v1.compute.instances.updateNetworkInterface"
   AND protoPayload.resourceName:"karlv-foobar-01-enode"
   AND timestamp>="2026-09-24T00:00:00Z"' \
  --project=vast-on-cloud --format=json --limit=50
```

Alias-bearing requests often put `aliasIpRanges` on the **request** object (with `networkInterface` as the string `"nic0"`), not only under a nested NIC object.

---

## 5. Open questions for engineering

We do not own the assign path; these are questions where your reading would help:

1. **Intended concurrency** — Is it expected that multiple `cloud_cli assign_ip` processes run at once against the same instance NIC during deploy / VIP publish? If yes, is there a documented locking or merge strategy around fingerprint?
2. **Desired alias set per PATCH** — Should each `updateNetworkInterface` include (dummy + all currently required VIP aliases), or is subset-replace intentional for some HA flows?
3. **Caller** — Which VMS / install step invokes parallel `assign_ip` for replication VIPs (the dual-PID window)? We only see the `cloud_cli` side clearly.
4. **Recent change?** — Field reports this was less visible earlier last week on “same” bundles. We do not have a commit bisect; if anything changed in VIP publish parallelism, retry timing, or VIP count, that would be useful context. Timing-dependent races can also appear without a code change.
5. **Dummy `/32`** — Still required for the google-cloud-python limitation cited in TF? Understanding that constraint helps field interpret “EXTRA” aliases correctly.
6. **Larger clusters** — Field has seen the same fingerprint / partial-alias class of symptoms on larger (e.g. multi-node / ~8-node) deploys, not only 1-node lab clusters. If engineering already treats fingerprint mismatch lines as routine, it would help to know whether those are expected to be **always** followed by a successful merge of the full VIP set, and how that is verified (beyond `assign_ip returned 0` on a single IP).

---

## 5b. On “we see those errors all the time”

Fingerprint mismatch / `PreconditionFailed` / `Invalid fingerprint` lines in `cloud_cli` can look routine because:

- Retries often eventually log `succefully assigned ips=(...)` / `assign_ip returned 0` for **that one IP**.
- A later deploy or manual check may show “enough” VIPs present for basic mgmt access.
- The message is familiar in GCP optimistic-locking generally.

What the foobar timelines show in addition (worth separating from “harmless noise”):

| Familiar log line | What we also measured on the same timeline |
|-------------------|--------------------------------------------|
| `fingerprint mismatch` / retry | Two PIDs started `_update_network_interface` with the **same** fingerprint ~10–100ms apart |
| `assign_ip returned 0` for IP *A* | A later PATCH for IP *B* omitted *A* from `alias_ip_ranges` (replace-all subset) |
| Compute op `OK` | Cloud Audit payload was **PARTIAL** vs the reserved VIP set |
| Retry succeeds | Final NIC can still be missing a reserved VIP (e.g. mgmt-vip) while dummy `/32` remains |

So the open question is not “do fingerprint errors appear in logs?” — field agrees they do. It is whether **routine** fingerprint traffic is always accompanied by a final NIC state that matches the **full** reserved VIP/internal set for that cluster. On the clusters above, that end-state check failed at points during/after install even when individual assigns reported success.

A cheap validation either side can run after VIP publish (no code change required):

```bash
# Reserved VIP/internal (exclude dns-vip if DNS not enabled) vs eNode aliases
./gcp.voc_alias_attach_audit.sh <CLUSTER> -p <PROJECT> --no-logs   # section [3]
# or with cloud_cli evidence:
./gcp.voc_alias_attach_audit.sh <CLUSTER> -p <PROJECT>
```

If engineering already has an equivalent post-condition in CI / install health, pointing us at it would close the loop.

---

## 6. What we are *not* claiming

- We are **not** asserting a root-cause commit or owning a patch.
- We are **not** asking for a specific API redesign in this note.
- We are **not** saying every fingerprint log line equals a customer outage — only that on examined clusters the same window correlates with **partial / raced alias sets**, which is a stronger claim than log noise alone.
- DNS VIP left `RESERVED` until DNS is enabled looks like expected product behavior from what we see in Polaris TF/defaults; it is out of scope for the fingerprint discussion.
- Intermittent success on other clusters is compatible with a timing-dependent race; absence of failure on a given deploy does not by itself disprove the concurrent-fingerprint pattern above.

If anything above misreads `cloud_cli` / VMS behavior, corrections are welcome — happy to adjust the field audit script to match the intended model.
