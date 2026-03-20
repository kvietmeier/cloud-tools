import sys
import os

# --- [1/4] NATIVE LIBRARY IMPORT ---
try:
    import google.auth
    from google.cloud import resourcemanager_v3
    from google.cloud import compute_v1
except ImportError:
    print("\n[FAIL] SDK Libraries missing. Run: pip install google-cloud-resource-manager google-cloud-compute")
    sys.exit(1)

# --- [2/4] THE FULL VAST DATASET ---
IAM_GROUPS = {
    "Cloud Functions": ["cloudfunctions.functions.create", "cloudfunctions.functions.delete", "cloudfunctions.functions.get", "cloudfunctions.functions.getIamPolicy", "cloudfunctions.functions.setIamPolicy", "cloudfunctions.operations.get"],
    "Compute Engine": ["compute.addresses.createInternal", "compute.addresses.deleteInternal", "compute.addresses.get", "compute.addresses.setLabels", "compute.addresses.useInternal", "compute.disks.create", "compute.disks.setLabels", "compute.healthChecks.create", "compute.healthChecks.delete", "compute.healthChecks.get", "compute.healthChecks.use", "compute.images.get", "compute.images.useReadOnly", "compute.instanceGroupManagers.create", "compute.instanceGroupManagers.delete", "compute.instanceGroupManagers.get", "compute.instanceGroups.create", "compute.instanceGroups.delete", "compute.instanceGroups.get", "compute.instanceTemplates.create", "compute.instanceTemplates.delete", "compute.instanceTemplates.get", "compute.instanceTemplates.useReadOnly", "compute.instances.create", "compute.instances.get", "compute.instances.setLabels", "compute.instances.setMetadata", "compute.instances.setTags", "compute.regionOperations.get", "compute.subnetworks.get", "compute.subnetworks.use", "compute.resourcePolicies.create", "compute.resourcePolicies.delete", "compute.resourcePolicies.get"],
    "IAM & SAs": ["iam.roles.create", "iam.roles.delete", "iam.roles.get", "iam.roles.undelete", "iam.serviceAccounts.actAs", "iam.serviceAccounts.create", "iam.serviceAccounts.delete", "iam.serviceAccounts.get"],
    "Resource Manager": ["resourcemanager.projects.get", "resourcemanager.projects.getIamPolicy", "resourcemanager.projects.setIamPolicy"],
    "Secret Manager": ["secretmanager.secrets.create", "secretmanager.secrets.delete", "secretmanager.secrets.get", "secretmanager.versions.access", "secretmanager.versions.add", "secretmanager.versions.destroy", "secretmanager.versions.enable", "secretmanager.versions.get"],
    "Cloud Storage": ["storage.buckets.create", "storage.buckets.delete", "storage.buckets.get", "storage.objects.create", "storage.objects.delete", "storage.objects.get"]
}

PORT_GROUPS = {
    "Network Services (TCP)": [
        ("22", "tcp", "SSH"), ("80", "tcp", "HTTP"), ("111", "tcp", "rpcbind"),
        ("389", "tcp", "LDAP"), ("443", "tcp", "HTTPS"), ("445", "tcp", "SMB"),
        ("636", "tcp", "Secure LDAP"), ("2049", "tcp", "NFS"), 
        ("3268", "tcp", "LDAP Catalogue"), ("3269", "tcp", "LDAP Catalogue SSL"),
        ("4420", "tcp", "spdk target"), ("4520", "tcp", "spdk target"),
        ("5000", "tcp", "Docker registry"), ("6126", "tcp", "mlx sharpd"),
        ("9090", "tcp", "Tabular"), ("9092", "tcp", "Kafka"),
        ("20048", "tcp", "mount"), ("20106", "tcp", "NSM"),
        ("20107", "tcp", "NLM"), ("20108", "tcp", "NFS_RQUOTA")
    ],
    "VAST Processes (TCP/UDP)": [
        ("3128", "tcp", "Call Home Proxy"), ("4000", "tcp", "Dnode Internal"),
        ("4001", "tcp", "Dnode Internal"), ("4100", "tcp", "Dnode Internal"),
        ("4101", "tcp", "Dnode Internal"), ("4200", "tcp", "Cnode Internal"),
        ("4201", "tcp", "Cnode Internal"), ("5200", "tcp", "Cnode Internal data"),
        ("5201", "tcp", "Cnode Internal data"), ("5551", "tcp", "vms_monitor"),
        ("6000", "tcp", "leader"), ("6001", "tcp", "leader"),
        ("7000", "tcp", "Dnode Internal"), ("7100", "tcp", "Dnode Internal"),
        ("7101", "tcp", "Dnode Internal"), ("8000", "tcp", "mcvms"),
        ("4001", "udp", "Dnode Internal"), ("4005", "udp", "Dnode1 Platform CAS"),
        ("4101", "udp", "Dnode Internal"), ("4105", "udp", "Dnode1 Data CAS"),
        ("4205", "udp", "CAS Operations"), ("5205-5239", "udp", "Cnode Silos CAS"),
        ("6005", "udp", "Leader CAS"), ("7005", "udp", "Dnode2 Platform CAS"),
        ("7105", "udp", "Dnode2 Data CAS")
    ],
    "Optional & RDMA Services": [
        ("1611", "tcp", "vperfsanity"), ("1612", "tcp", "vperfsanity"),
        ("2611", "tcp", "netbench"), ("49001", "tcp", "Replication"),
        ("49002", "tcp", "Replication"), ("53", "udp", "DNS"),
        ("20049", "tcp", "nfs/RDMA")
    ]
}

class VastLibraryValidator:
    def __init__(self, project_id, vpc_name, region=None):
        self.project_id = project_id
        self.project_path = f"projects/{project_id}"
        self.vpc_name = vpc_name
        self.region = region or "us-central1"
        
        self.creds, _ = google.auth.default()
        
        self.rm_client = resourcemanager_v3.ProjectsClient(credentials=self.creds)
        self.fw_client = compute_v1.FirewallsClient(credentials=self.creds)
        self.sn_client = compute_v1.SubnetworksClient(credentials=self.creds)
        self.region_client = compute_v1.RegionsClient(credentials=self.creds)

    def check_pga_subnets(self):
        print(f"\n[*] INFRA: Region {self.region} PGA Check (VPC: {self.vpc_name})")
        print("-" * 95)
        try:
            request = compute_v1.AggregatedListSubnetworksRequest(project=self.project_id)
            found = False
            for region_url, response in self.sn_client.aggregated_list(request=request):
                if self.region not in region_url: continue
                if response.subnetworks:
                    for sn in response.subnetworks:
                        if self.vpc_name in sn.network:
                            found = True
                            status = "[PASS]" if sn.private_ip_google_access else "[FAIL]"
                            print(f"  {status} Subnet: {sn.name:<40} | PGA: {sn.private_ip_google_access}")
            if not found: print(f"  [WARN] No subnets found in {self.region} for VPC {self.vpc_name}")
        except Exception as e: print(f"  [FAIL] API Error: {e}")

    def audit_quotas(self):
        """Checks for Z3 Storage-Optimized CPUs and SSD Limits."""
        print(f"\n[*] QUOTAS: VAST Z3 Specific Availability ({self.region})")
        print("-" * 95)
        
        try:
            region_info = self.region_client.get(project=self.project_id, region=self.region)
            targets = {
                'Z3_CPUS': 'Z3 CPUs (Storage Opt)', 
                'SSD_TOTAL_GB': 'Total SSD (GB)', 
                'CPUS': 'Total CPUs',
                'DISKS_TOTAL_GB': 'Total Disk (GB)'
            }
            # Track which we found to alert on missing Z3 quota entirely
            found_metrics = []
            for q in region_info.quotas:
                if q.metric in targets:
                    found_metrics.append(q.metric)
                    usage, limit = int(q.usage), int(q.limit)
                    percent = (usage / limit * 100) if limit > 0 else 0
                    status = "[WARN]" if percent > 85 else "[PASS]"
                    print(f"  {status} {targets[q.metric]:<20} | Usage: {usage}/{limit} ({percent:.1f}%)")
            
            if 'Z3_CPUS' not in found_metrics:
                print(f"  [FAIL] Z3_CPUS metric not found in {self.region}. Is Z3 available in this region?")
        except Exception as e: print(f"  [FAIL] Quota API Error: {e}")

    def verify_iam_native(self):
        print(f"\n[*] IAM: Granular Permission Audit")
        print("-" * 95)
        all_perms = [p for group in IAM_GROUPS.values() for p in group]
        try:
            response = self.rm_client.test_iam_permissions(resource=self.project_path, permissions=all_perms)
            granted = set(response.permissions)
            for group, perms in IAM_GROUPS.items():
                missing = [p for p in perms if p not in granted]
                status = "[PASS]" if not missing else "[FAIL]"
                print(f"  {status} {group:<20} | Verified: {len(perms)-len(missing)}/{len(perms)}")
                if missing:
                    for m in missing: print(f"      - Missing: {m}")
        except Exception as e: print(f"  [FAIL] IAM API Error: {e}")

    def audit_firewall(self):
        print(f"\n[*] NETWORK: Firewall Rules (VPC: {self.vpc_name})")
        print("-" * 95)
        try:
            rules = list(self.fw_client.list(project=self.project_id))
            vpc_rules = [r for r in rules if self.vpc_name in r.network and r.direction == "INGRESS" and not r.disabled]
            for group, ports in PORT_GROUPS.items():
                print(f"\n  --- {group} ---")
                for port, proto, desc in ports:
                    match_name = self._find_matching_rule(port, proto, vpc_rules)
                    status = "[PASS]" if match_name else "[FAIL]"
                    print(f"    {status} {proto.upper():<5} {port:<12} | {desc:<25} -> {match_name or 'MISSING'}")
        except Exception as e: print(f"  [FAIL] Firewall API Error: {e}")

    def _find_matching_rule(self, req_p, req_proto, rules):
        for r in rules:
            for allow in r.allowed:
                if allow.I_p_protocol == 'all' or allow.I_p_protocol == req_proto:
                    if not allow.ports: return r.name
                    if any(self._is_port_in_range(req_p, rp) for rp in allow.ports): return r.name
        return None

    def _is_port_in_range(self, req, rule_p):
        try:
            rmin, rmax = (map(int, rule_p.split('-')) if '-' in rule_p else (int(rule_p), int(rule_p)))
            qmin, qmax = (map(int, req.split('-')) if '-' in req else (int(req), int(req)))
            return rmin <= qmin and rmax >= qmax
        except: return False

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 gcp_validate.py <PROJECT_ID> <VPC_NAME> [REGION]")
    else:
        target_region = sys.argv[3] if len(sys.argv) > 3 else "us-central1"
        v = VastLibraryValidator(sys.argv[1], sys.argv[2], target_region)
        v.check_pga_subnets()
        v.audit_quotas()
        v.verify_iam_native()
        v.audit_firewall()