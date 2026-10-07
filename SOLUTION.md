## Task 1 — Terraform

### Assumptions and Findings

Root main.tf (lines 44–49) used ";" inside single-line variable blocks, which is invalid HCL,
so terraform init failed before validate could run. README says "do not modify" but also requires
validate to pass, so I converted them to multi-line blocks. Syntax only: names, types, defaults,
and module blocks are unchanged.

```text
VPC (10.10.0.0/16) --> Main CIDR /16 --> 65.536 available IPs
4 octets (32 bits)
           |---- 10 octet 1 -> 8 bit locked
           |---- 10 octet 2 -> 8 bit locked
           |---- 0 octet 3 -> 8 bits free
           |---- 0 octet 4 -> 8 bits free
```

```text
cidrsubnet(var.vpc_cidr, 4, count.index)
cidrsubnet( prefix , newbits , netnum )
             │         │         └─ subnet number taken
             │         └─ 4 (means take 4 bits from VPC free range and make it as subnet number) 2^4 --> 16 subnets available
             └─ parent block (10.10.0.0/16)
```

**Why 4?** Because we need 3 tier and 3 az for each, so it means 3x3 = 9 subnets are required. 2^4 = 16 subnets are sufficient, if we choose 3, 2^3 = 8 wont be enough.

```text
/16 + 4 new bits = /20 per subnet → 32 − 20 = 12 host bits → 2^12 = 4,096 IPs each subnet
```

```hcl
cidr_block         = cidrsubnet(var.vpc_cidr, 4, count.index)

availability_zones = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
count              = length(var.availability_zones) # --> means this will looping index (0,1,2) / az a,b,c
```

#### Subnetting range

```text
octet 3 start = subnetNum × 16
octet 3 ends  = startRes + 15 (logic)
range         = 10.10.<start>.0 - 10.10.<ends>.255
```

**a. Subnet Web** → `cidr_block = cidrsubnet(var.vpc_cidr, 4, count.index)`

offset +0, count.index 0 (subnet 0), count.index 1 (subnet 1), count.index 2 (subnet 2)

- Web[0] AZ 3a CIDR `10.10.0.0/20`
  - Start: 0 x 16 = 0 --> 10.10.0.0
  - Ends: 0 + 15 = 15 --> 10.10.15.255
- Web[1] AZ 3b CIDR `10.10.16.0/20`
  - Start: 1 x 16 = 16 --> 10.10.16.0
  - Ends: 16 + 15 = 31 --> 10.10.31.255
- Web[2] AZ 3c CIDR `10.10.32.0/20`
  - Start: 2 x 16 = 32 --> 10.10.32.0
  - Ends: 32 + 15 = 47 --> 10.10.47.255

**b. Subnet App** → `cidr_block = cidrsubnet(var.vpc_cidr, 4, count.index + 4)`

offset +4, count.index 0 (subnet 4), count.index 1 (subnet 5), count.index 2 (subnet 6)

- App[0] AZ 3a CIDR `10.10.64.0/20`
  - Start: 4 x 16 = 64 --> 10.10.64.0
  - Ends: 64 + 15 = 79 --> 10.10.79.255
- App[1] AZ 3b CIDR `10.10.80.0/20`
  - Start: 5 x 16 = 80 --> 10.10.80.0
  - Ends: 80 + 15 = 95 --> 10.10.95.255
- App[2] AZ 3c CIDR `10.10.96.0/20`
  - Start: 6 x 16 = 96 --> 10.10.96.0
  - Ends: 96 + 15 = 111 --> 10.10.111.255

**c. Subnet Protected** → `cidr_block = cidrsubnet(var.vpc_cidr, 4, count.index + 8)`

offset +8, count.index 0 (subnet 8), count.index 1 (subnet 9), count.index 2 (subnet 10)

- Protected[0] AZ 3a CIDR `10.10.128.0/20`
  - Start: 8 x 16 = 128 --> 10.10.128.0
  - Ends: 128 + 15 = 143 --> 10.10.143.255
- Protected[1] AZ 3b CIDR `10.10.144.0/20`
  - Start: 9 x 16 = 144 --> 10.10.144.0
  - Ends: 144 + 15 = 159 --> 10.10.159.255
- Protected[2] AZ 3c CIDR `10.10.160.0/20`
  - Start: 10 x 16 = 160 --> 10.10.160.0
  - Ends: 160 + 15 = 175 --> 10.10.175.255

---

### 1a: NACL Fixes

**Context**

Pod with IP `100.64.0.0/16` cannot connect to `10.10.128.0/20`, `10.10.144.0/20`, `10.10.160.0/20` with port 5432 (RDS Proxy) and 6379 (Redis).

**Bugs Found**

1. **inbound** = rule 100 (5432) and 110 (6379) only allows `10.10.64.0/20`. The pod IP not match, so it hit `*` DENY.
2. **egress** = Rule egress 100 (ephemeral 1024–65535) only to `10.10.64.0/20`. NACL is stateless, so the reply back to pod is dropped even though request pass through before.
3. **additional** = `10.10.64.0/20` only for app subnet AZ-a (slot 4). Node in AZ-b and AZ-c will also blocked too.

**Why silent drops**

- NACL just drops packets in the VPC network without sending anything back, no connection reset or destination unreachable response.
- Reset can only be sent by the target host's TCP stack. But the packet never even reach the host, so reset output is not send.
- The client (pods) keep retrying SYN and then ends up with `ETIMEDOUT`.
- It causing looks like the host is dead or no route, making it harder to debug than `ECONNREFUSED`.

**Fixing**

1. Add new nacl rule using local:

   ```hcl
   locals {
     app_cidr       = "10.10.64.0/18"
     pod_cidr       = "100.64.0.0/16"  # VPC CNI custom networking pod IPs
     protected_cidr = "10.10.128.0/18" # protected subnets, all 3 AZs
   }
   ```

   - **Why /18?** To include a wider range of octets 3 10.10.64-127 and not including web tier subnet (public purpose 0-47).
   - **Why pod cidr added?** Because the packet actually pass through the node network card `10.10.68.45`, but the source IP isnt changed to the node IP. VPC CNI only do the replacement (SNAT) if the destination is outside VPC. Database is inside the VPC, so source IP stay `100.64.4.17`.

     When packet arrive at the gate of protected subnet, NACL will check:

     ```text
     Source 100.64.4.17 match with 10.10.64.0/20? → NO → DROP
     ```

     NACL doesnt know, and dont care, that the packet "coming from node 10.10.68.45". It only check the source IP column content. So, the node `10.10.68.45` itself able to resolve the connection. In that case the source IP is `10.10.68.45`, and NACL allow it.

2. New NACL rules added for bothway ingress-egress — refer to git diff `task1-terraform/modules/networking/nacl.tf` line 71-210.

---

### 1b: RDS Module — Bugs Fixed

**Context**

```text
pod ──5432──► [SG rds_proxy] RDS Proxy ──5432──► [SG rds] RDS PostgreSQL
```

- RDS SG only accept from rds_proxy SG, so RDS can only be accessed through proxy.
- SG rds_proxy accept from node or pod, then it forward to RDS SG.

**Bugs Found**

1. **Circular dependency between SG**

   The problem is: terraform create resource based on dependency order. To create rds SG, Terraform need the rds_proxy SG ID (because it used in ingress block). To create rds_proxy SG, Terraform need the rds SG ID (because it used in egress block).

   ```text
   rds SG ──need ID──► rds_proxy SG ──need ID──► rds SG ──► ... (looping forever)
   ```

2. **SG proxy doesnt allow pod**

   Existing:
   - proxy SG only accept from ENI that use node SG (`eks_node_sg_id`).
   - pod use IP `100.64.x.x`, which is coming from additional ENI for pod (custom networking).
   - SG that attached to pod ENI is configured in ENIConfig, and the content is not always node SG.

   Mismatch:

   ```text
   Packet: 100.64.4.17 → Proxy:5432
   proxy SG check: does sender ENI use node SG? → (according to problem) NO → DROP
   ```

3. **Wrong placement for RDS Subnet**

   Concept: DB subnet group. RDS is not attached to single subnet, but to one "subnet group" (minimum 2 AZ). RDS choose subnet from that group for primary and standby instance (because `multi_az = true`).

   The problem is: that subnet group contain web subnets (10.10.0–47.x). Web subnet has route `0.0.0.0/0 → IGW` (`aws_route_table.web` in `networking/main.tf`). RDS is not exposed today only because `publicly_accessible` is false by default. If that flag change, RDS can be accessed directly from internet. In protected subnet, same mistake don't have impact because there is no route to IGW. This is defense in depth point.

   NACL protected from 1a is not protecting RDS at all, because RDS is not inside protected subnet.

4. **To Do TLS**

   Without `rds.force_ssl = 1`, RDS still accept connection without TLS, so password and query can be sent without encryption.

**Fixes**

1. Create empty SG for both rds proxy sg and rds sg, then create separate sg rule to be attached to both SG.
2. New rule added for ingress from pods `100.64.0.0/16`.
3. Change `aws_db_subnet_group.web` into `aws_db_subnet_group.protected` with `var.protected_subnet_ids`.
4. Change `aws_db_parameter_group.app` (`postgres16`, `rds.force_ssl = 1`), and attached to RDS via `parameter_group_name`.
5. I delete the egress allow-all on SG (least privilege). SG is stateful, so replies to the proxy are still allowed.

---

### 1b: RDS Proxy — Design Decisions

**Context**

For Subnet protected SG rds_proxy, add value of `idle_client_timeout = 1800`, `iam_auth = "DISABLED"`, `connection_borrow_timeout = 5`.

**Fixes**

1. **`idle_client_timeout = 1800`**
   - This value is same as AWS default, and it match for web app that use connection pool, like in this app.
   - Connection that is totally unused (for example pod that die without closing connection) is finally cleaned up, so proxy resource dont leak.

2. **`vpc_security_group_ids = [aws_security_group.rds_proxy.id]`**
   Why SG rds_proxy: This SG is specifically designed for proxy (via fix BUG 1 and 2):
   - Accept port 5432 from node SG and from pod CIDR `100.64.0.0/16`.
   - Only allowed outbound to rds SG on port 5432.
   - rds SG itself only accept from rds_proxy SG. So if proxy dont use this SG, proxy cannot get into RDS.

3. **`vpc_subnet_ids = var.protected_subnet_ids`**
   Why protected:
   - Proxy only talk to two sides: pod (inbound) and RDS (outbound). Proxy dont need internet at all.
   - Proxy become one tier with RDS, so NACL protected from 1a also protecting it too.

4. **`iam_auth = "DISABLED"`**
   Why DISABLED:
   - App use normal username/password. The proof is in task 3: `DATABASE_URL: postgresql://helios_app:***@...proxy...`, which contain static password in the connection string.
   - Proxy fetch credentials from Secrets Manager (`auth_scheme = "SECRETS"` and `secret_arn`) using IAM role `role_arn`.

5. **`connection_borrow_timeout = 5`**
   - AWS default is 120 seconds. With 120 seconds, when DB is busy, hundreds of request will wait up to 2 minutes, app will be full of waiting requests, and the problem make everything broken.

**Test Results:**

```text
$ cd task1-terraform
$ terraform init
$ terraform validate
Initializing the backend...

Initializing modules...

Initializing provider plugins...
- Reusing previous version of hashicorp/aws from the dependency lock file
- Using previously-installed hashicorp/aws v5.100.0

Terraform has been successfully initialized!

You may now begin working with Terraform. Try running "terraform plan" to see
any changes that are required for your infrastructure. All Terraform commands
should now work.

If you ever set or change modules or backend configuration for Terraform,
rerun this command to reinitialize your working directory. If you forget, other
commands will detect it and remind you to do so if necessary.
Success! The configuration is valid.
```


---

## Task 2 — Kubernetes

### 2a: NodePool Design Decisions

**Assumptions**

1. **NodeClass type.** `nodeclass.yaml` uses `eks.amazonaws.com/v1` `NodeClass` (EKS Auto Mode), but its fields (`amiFamily`, `blockDeviceMappings`, `metadataOptions`) belong to OSS Karpenter `EC2NodeClass`.
   so both NodePools reference it as-is (`group: eks.amazonaws.com`, `kind: NodeClass`, `name: helios-ai-default`) and use `eks.amazonaws.com/*` instance labels to stay consistent.
2. **Subnets / AZs.** NodeClass selects subnets by tag `karpenter.sh/discovery: helios-ai-prod`.
   In Task 1 Terraform only the app subnets carry this tag, so nodes land in the 3 app subnets (3a/3b/3c).
   No zone requirement in the NodePools, so Karpenter can use all 3 AZs.
3. **Architecture.** `amd64` only. The app image is not confirmed multi-arch.
   Graviton (`arm64`) could cut cost later if the image supports it.
4. **System pods.** Both pools are tainted, so CoreDNS / Karpenter controller / other system pods are assumed to run on a separate system node group.

**Design**

1. **App pools:**
   - `c` = compute-optimized, match for CPU-intensive prompt routing.
   - `m` = general purpose. This add more instance type to spot pool, so less chance for spot capacity shortage or interruption.
   - Gen > 5: newer generation give better price and performance.
   - 8–16 vCPU:
     - Lower bound: 8 vCPU node can fit 3 pods (2 CPU each) after system reserve.
     - Upper bound: so we don't have one big node hold all pods. If single spot interruption happen, it will kill the whole gateway (blast radius).
   - Capacity check:
     - Normal: 8 pods → need 3 x 8 vCPU nodes = 24 CPU.
     - KEDA max: 20 pods → need 7 nodes = 56 CPU / 112Gi (if use `c`). Still safe inside 80 CPU / 160Gi.
   - Notes: if Karpenter choose `m` (32Gi per 8 vCPU), the 160Gi memory limit will hit at 5 nodes, which is only enough for like 15 pods. `c` is usually more cheap per vCPU so it is better, but this is known limit trade-off.

2. **DB Pools:**
   - `r` = memory-optimized. Postgres is good if use big buffer cache, and Redis keep all data in memory.
   - `m` = general purpose. Better CPU and memory balance for the tight limit.
   - 8 vCPU only:
     - Postgres request 4 CPU, so it cannot fit in 4 vCPU node (allocatable is less than 4).
     - 16 vCPU is useless: `r` 16 vCPU = 128Gi already pass the 64Gi limit, and `m` 16 vCPU = 64Gi will use all the pool in just one node.
   - Notes: Limit analysis, 16 CPU / 64Gi means maximum only 2 nodes (2 x `m.2xlarge`), or 1 x `r.2xlarge` (64Gi already use all memory limit). So the `nodes: 4` limit is never the real problem. If want to reach 4 nodes, we must make the CPU and memory limit bigger first.

**Spot vs On-Demand**

- The app uses Spot with On-Demand as a backup because it's stateless and has retries mechanism enabled.
- The DB uses On-Demand only because the 2-minute spot interruption notice is not enough for a database to shut down safely

**Disruption**

- The app uses consolidation to save costs.
- The DB uses `Never`, budget `0`, and `expireAfter: Never` because consolidation, drift, and expiry can all kill the database.

**Taint and Toleration**

- Taints reject other pods, and `nodeSelector` to the `node_group` label pulls the right pods into its pool. Both are needed.
- workload pods must have a matching toleration (`workload=app:NoSchedule` / `workload=db:NoSchedule`), otherwise they will get rejected by the taint and just stay Pending.

**Potential Issue**

1. **AMI Drift** = AMI is not pinned in the nodeclass.
2. **App nodepools** = Nodes will rollout after reaching the 30-day `expireAfter` limit, and it can replaced together. budget wont handled it, only PDB can hold the rollout from pods application side.

**Enhancement**

1. **App nodepools** = Continuous rollout will happen if `consolidateAfter` is too short (1 minute). This won't tolerate pods with fast, dynamic usage.
   Thats why i changed from `1m` -> `5m` this will align with HPA scale-down window. `1m` too aggressive, `1h` wastes cost after spikes.

### 2b: KEDA ScaledObject — Bugs Fixed

**1. Bug 1: No fallback defined**

With existing configuration:

```yaml
spec:
  scaleTargetRef:
    name: helios-llm-gateway
  minReplicaCount: 2
  maxReplicaCount: 20
  cooldownPeriod: 60
  pollingInterval: 15
```

If the failure happens (mimir/prometheus died) this will running on minimum pods 2, but as per context from `nodepools.yaml`, this application pods are running on daily usage 2-8. Which 2 is the lower bound and I marked as high probability issue. So I create fallback with upper bound number 8, and threshold failure 4 to create a better tolerable number of time.

```yaml
  fallback:
    failureThreshold: 4   # 4 times failed asking for metrics. 4 x 15 (default periodSync) = 1 minute of unavailability before fallback triggers
    replicas: 8           # safe number of replicas to hold if Prometheus is unavailable, in this context 2a pods helios-llm-gateway running in between 2-8 pods for daily usage.
```

**2. Bug 2: Wrong pointing of serverAddress**

KEDA query public endpoint that might not contain this cluster metric or cannot be reached from inside the cluster, so scaling will use wrong data or fail, and it also add latency and leak metrics to outside.

Mimir are internal svc with below details:

```text
mimir-svc . monitoring . svc . cluster.local : 9009 / prometheus
   │           │                    │            │        └─ Mimir's Prometheus-compatible API path
   │           │                    │            └─ port
   │           │                    └─ cluster internal domain
   │           └─ namespace
   └─ Service name
```

So replacing the public endpoint prometheus with `http://mimir-svc.monitoring.svc.cluster.local:9009/prometheus` should be the best answer.

**3. Bug 3: Threshold 1000**

If the number of safe concurrent number for 1 pods are 10, so replacing the 1000 --> 10 might the options by below calculations logic:

```text
replica = ceil(total request / threshold)
```

If total request --> 50:

- With threshold 1000 = ceil(50/1000) = 0.05 -> 1 pods marked as enough, which actually pods might be dropped bcs pods only able to resolve 10 connection safely. But this will fallback to default minimum pods: 2 (still not enough).
- With threshold 10 = ceil(50/10) = 5 pods, which actually safe bcs each pods will handled at least ~10 concurrent connections.

**4. Bug 4: P99 query**

Problem is:

- Without `rate()`, P99 is calculated from the whole history since the pod is alive. A latency spike in the last 5 minutes will "drown" inside millions of old requests, so the trigger will barely react.
- Without `sum ... by (le)` (less or equal), the result is one value per pod, not one single number. KEDA need one number, so query with many results will error.

Fix:

```promql
histogram_quantile(0.99,
  sum(rate(litellm_request_duration_seconds_bucket{service="helios-llm-gateway"}[5m])) by (le)
)
```

Why:

- `rate(...[5m])`: rate per second in the last 5 minutes, so only the newest data is used.
- `sum(...) by (le)`: combine all the pods, but keep the `le` label that is needed to calculate percentile.
- `histogram_quantile(0.99, ...)`: calculate P99 from that combination.
- `{service="helios-llm-gateway"}`: filter so it only take this gateway metric, same like trigger 1.

**5. Bug 5: CPU threshold**

Pods request from 2a mentioned 2 CPU. Pod cannot use CPU more than its limit. If limit is same like request (2 CPU), the max utilization is 100%, so the number 200 will never be reached and the CPU trigger is totally dead.

Fix:

- Change the threshold value into `70`.
- Pod request 2 CPU (from context 2a), then it use 1.4 CPU, which means the utilization is 70%. This number is the safest number.

**Test result:**

```text
$ kubectl apply --dry-run=client -f task2-k8s/nodepools/nodepools.yaml
$ kubectl apply --dry-run=client -f task2-k8s/scaledobjects/llm-gateway-scaledobject.yaml
nodepool.karpenter.sh/helios-ai-app created (dry run)
nodepool.karpenter.sh/helios-ai-db created (dry run)
scaledobject.keda.sh/helios-llm-gateway-so created (dry run)
```
---

## Task 3 — Incident

### 3a: Root Cause Analysis

#### RC1: RDS Proxy is inside web subnet (public), and proxy SG dont allow pod CIDR

**What happened?** helios-api cannot connect to database through RDS Proxy.

**Evidence?**

a. the output of `describe-db-proxies` show that `VpcSubnetIds` contain `subnet-0web1aaa`, `subnet-0web2bbb`, `subnet-0web3ccc`. all three is web subnet.

```text
# aws rds describe-db-proxies --db-proxy-name helios-ai-prod-app-proxy \
#   --query 'DBProxies[0].{Status:Status,Endpoint:Endpoint,VpcSubnetIds:VpcSubnetIds}'
{
  "Status": "available",
  "Endpoint": "helios-ai-prod-app.proxy-abc123.ap-southeast-3.rds.amazonaws.com",
  "VpcSubnetIds": [
    "subnet-0web1aaa",
    "subnet-0web2bbb",
    "subnet-0web3ccc"
  ]
}
```

b. In `application.log` there is connect `ETIMEDOUT 10.10.16.45:5432`. proxy endpoint is resolved to `10.10.16.45`, which is inside the range of Web[1] AZ-b (`10.10.16.0/20`, 10.10.16–31.x).
This match with my CIDR calculation in task1.

```text
2026-10-01T14:32:12Z ERROR [helios-api] Error: connect ETIMEDOUT 10.10.16.45:5432
```

**Assumptions:** The error is `ETIMEDOUT`, not `ECONNREFUSED`. it means the packet is dropped silently by network layer (SG or NACL).
If packet reach the proxy then get rejected, the error will be connection refused

**Why it happened?** in Terraform there is no special NACL for web subnet, so web subnet use default NACL which is allow-all. this is just assumption,
because web NACL output is not shown. So, the one that drop the packet is proxy SG. proxy SG only allow node SG (`var.eks_node_sg_id`), while the packet come from pod IP `100.64.4.17`. This is Task 1b BUG 2.

**Why web subnet is wrong?** Web subnet has route `0.0.0.0/0 → IGW`, so the database tier is inside a tier that face the internet.
there is hidden issue: even if pod→proxy is already working, the step proxy→RDS will also fail. RDS is in protected subnet, and protected NACL dont allow source `10.10.16.x` (web).

#### RC2: NACL protected only allow 10.10.64.0/20 (node CIDR, AZ-a only)

**What happend?** all traffic coming from pod to protected tier subnet is dropped, both Postgres (5432) and Redis (6379).

**Evidence?**

a. Protected NACL only allows `10.10.64.0/20` for 5432, 6379, and ephemeral egress. everything else hits rule 32767 DENY.

```text
# aws ec2 describe-network-acls --filters "Name=tag:Name,Values=helios-ai-prod-nacl-protected" \
#   --query 'NetworkAcls[0].Entries' --output table

RuleNumber | Protocol | Action | Egress | CidrBlock      | PortRange
-----------|----------|--------|--------|----------------|----------
100        | tcp      | allow  | false  | 10.10.64.0/20  | 5432-5432
110        | tcp      | allow  | false  | 10.10.64.0/20  | 6379-6379
100        | tcp      | allow  | true   | 10.10.64.0/20  | 1024-65535
32767      | -1       | deny   | false  | 0.0.0.0/0      | -
32767      | -1       | deny   | true   | 0.0.0.0/0      | -
```

b. The pod IP is `100.64.4.17` on node `10.10.68.45`.

```text
Name:         helios-api-7d9f8b6c4-xk2qp
Namespace:    helios-ai
Node:         ip-10-10-68-45.ap-southeast-3.compute.internal/10.10.68.45
Status:       Running
IP:           100.64.4.17
IPs:
  IP:  100.64.4.17
```

c. `100.64.4.17` is not inside `10.10.64.0/20`, so it is denied.
`10.10.64.0/20` also covers only App[0] AZ-a, so nodes in AZ-b and AZ-c are blocked too.

**Why it happened?** with VPC CNI custom networking, pods get IP from `100.64.0.0/16`. there is no SNAT for traffic inside VPC, so NACL see the pod IP (`100.64.4.17`), not node IP (`10.10.68.45`). NACL is also stateless so even if inbound is allow, the reply back to pod is dropped by egress rule (only to `10.10.64.0/20`).

**Impact:**

- a. Redis (6379): Valkey is in protected subnet, so pod -> Valkey is dropped directly.
- b. Postgres (5432): not visible in log yet, because proxy is still in web subnet (RC1). once proxy is moved to protected, pod -> proxy will get dropped by this NACL too.

#### RC3: Redis TLS mismatch (client plaintext, server require TLS)

**What happened?** helios-worker cannot connect to Valkey, job queue is not available, and worker stay idle.

**Evidence?**

```text
2026-10-01T14:33:02Z ERROR [helios-worker] Redis connection failed: Error: connect ECONNREFUSED
```

**Why it happened?** because from replications groups

```text
# aws elasticache describe-replication-groups \
#   --replication-group-id helios-ai-prod-valkey \
#   --query 'ReplicationGroups[0].{TransitEncryptionEnabled:TransitEncryptionEnabled,TransitEncryptionMode:TransitEncryptionMode,AtRestEncryptionEnabled:AtRestEncryptionEnabled}'
{
  "TransitEncryptionEnabled": true,
  "TransitEncryptionMode": "required",
  "AtRestEncryptionEnabled": true
}
```

it mentioned ransitEncryptionEnabled: true and `TransitEncryptionMode: "required"` means server only accept TLS connection.
but the ConfigMap uses plaintext on both settings: `REDIS_URL` uses the `redis://` scheme (TLS needs `rediss://`) and `REDIS_SSL` is `"false"`, so the client connects without TLS and the server rejects it.

**My Reasoning:**
with the current NACL, port 6379 from pod CIDR should be dropped and get `ETIMEDOUT`, before getting REFUSED.
also, plaintext client connecting to Valkey with TLS required usually gets connection reset/closed in real life, not refused.
but for now, log is assumed to represent TLS handshake failure; in real life condition,
worker will hit two layer of problems: NACL (timeout) first, then TLS after NACL is opened.

---

### 3b: Remediation Plan

**1.** change the configmap for SSL: false into `REDIS_SSL: "true"` and "redis//" to `"rediss://"` to switch with TLS and encrypted.

```yaml
data:
  REDIS_URL: "rediss://master.helios-ai-prod-valkey.abc.apse3.cache.amazonaws.com:6379"
  REDIS_SSL: "true"
```

**2.**

```bash
kubectl apply -f task3-incident/manifests/helios-api-configmap.yaml
kubectl rollout restart deployment/helios-api -n helios-ai
kubectl rollout restart deployment/helios-worker -n helios-ai # --> assumptions
```

**3.** change the terraform for NACL of protected subnet, example;

```hcl
resource "aws_network_acl_rule" "protected_inbound_postgres_pods" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 101
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.pod_cidr
  from_port      = 5432
  to_port        = 5432
}
```

this method has been applied on task 1a, to allow `cidr_block` which previously defined on `local.pod_cidr`
full set in `nacl.tf`: ingress 101 (5432) and 111 (6379) from pod CIDR, egress 101 ephemeral 1024-65535 to pod CIDR (NACL is stateless),
and `app_cidr` widened from /20 to /18 to cover all 3 AZs. Rules 120/130 allow proxy -> RDS inside the protected tier.

**4.** recreate rds proxy. this is needed because we required to change the subnet that will assigned to rds proxy. in this case
changing from web subnet (public tier) into protected subnet.

```hcl
resource "aws_db_proxy" "app" {
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]
  vpc_subnet_ids         = var.protected_subnet_ids
}
```

replacing rds proxy will create the same endpoint proxy url as long as the name of the rds proxy are still same. (no pointin needed from application side, but still need further verification)
and then for the rds proxy sg this require to attach new sg rule that has been created also on terraform task 1

```hcl
resource "aws_security_group_rule" "rds_proxy_ingress_from_pods" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = ["100.64.0.0/16"]
  security_group_id = aws_security_group.rds_proxy.id
}
```

this to allow the connection from pods 100.64.x.x to rds proxy after NACL checking. (double layer).

---

### 3c: Prevention

#### Issue 1: RDS Proxy in web subnet (public tier)

**Prevention:** CI policy check config test on terraform plan JSON.
rule: `aws_db_proxy`, `aws_db_subnet_group`, and ElastiCache can only use subnet that have tag `tier=protected`. requires adding tag `tier=protected` to the protected subnets. or enforce it in the module with variable validation

**Why it catches it:** the PR will fail automatic before apply, dont care who write the code.

**Example** `policy/subnet_tier.rego`

```rego
package main

import rego.v1

# Subnet IDs tagged tier=protected (requires the tag on aws_subnet.protected)
protected_subnet_ids contains id if {
	some mod in input.planned_values.root_module.child_modules
	some r in mod.resources
	r.type == "aws_subnet"
	r.values.tags.tier == "protected"
	id := r.values.id
}

# Resource type -> attribute that holds its subnet IDs
subnet_attrs := {
	"aws_db_proxy": "vpc_subnet_ids",
	"aws_db_subnet_group": "subnet_ids",
	"aws_elasticache_subnet_group": "subnet_ids",
}

deny contains msg if {
	some change in input.resource_changes
	attr := subnet_attrs[change.type]
	some action in change.change.actions
	action in {"create", "update"}
	some subnet in change.change.after[attr]
	not subnet in protected_subnet_ids
	msg := sprintf("FAIL: %v uses subnet %v, which is not tagged tier=protected.", [change.address, subnet])
}
```

Usage: `terraform plan -out=tfplan && terraform show -json tfplan > plan.json && conftest test plan.json`.
Limitation: if the subnets are created in the same plan, their IDs are "known after apply", so this check works best once the subnets already exist.

#### Issue 2: Protected NACL missing pod CIDR

**Prevention:** IaC single source of truth. pod_cidr is just one variable/output from networking module, then reused by NACL, SG, and VPC CNI config. no more hardcoded CIDR in every rules.

**Why it catches it:** if pod CIDR change, all rule follow automatic, so no rule is forgotten.

**(optional) Monitoring:** VPC Flow Logs on protected subnet + alarm for REJECT count.

#### Issue 3: Redis TLS mismatch

**Prevention:** CI lint on manifest using conftest or kyverno that reject REDIS_URL starting with redis:// or REDIS_SSL "false" in prod.

**(better way)** generate REDIS_URL directly from Terraform ElastiCache output, so the scheme follow transit_encryption_mode.

**Why it catches it:** client config cannot be different from server setting, because it is checked or generated from the same source.

**Example** `policy/redis_tls.rego`

```rego
package main

import rego.v1

# REDIS_URL comes from ConfigMap helios-api-config (via configMapKeyRef), so check the ConfigMap
deny contains msg if {
	input.kind == "ConfigMap"
	input.metadata.namespace == "helios-ai"
	startswith(input.data.REDIS_URL, "redis://")
	msg := sprintf("FAIL: ConfigMap %v uses plaintext REDIS_URL. Use rediss:// because ElastiCache transit encryption is required.", [input.metadata.name])
}

deny contains msg if {
	input.kind == "ConfigMap"
	input.metadata.namespace == "helios-ai"
	input.data.REDIS_SSL == "false"
	msg := sprintf("FAIL: ConfigMap %v sets REDIS_SSL to \"false\". It must be \"true\" to match ElastiCache transit_encryption_mode.", [input.metadata.name])
}
```

Usage: `conftest test task3-incident/manifests/helios-api-configmap.yaml`
