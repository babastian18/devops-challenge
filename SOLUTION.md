## Task 1 — Terraform

### Assumptions and Findings

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

---

## Task 2 — Kubernetes

### 2a: NodePool Design Decisions
[your answer]

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

---

## Task 3 — Incident

### 3a: Root Cause Analysis
[your answer]

### 3b: Remediation Plan
[your answer]

### 3c: Prevention
[your answer]
