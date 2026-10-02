# SOLUTION TEMPLATE — Reviewer Copy
# DO NOT SHARE WITH CANDIDATE

> This document is the reviewer's answer guide and grading rubric.
> Use it to evaluate submitted SOLUTION.md files.

---

## Grading Summary Sheet

| Task | Max Points | Candidate Score | Notes |
|------|-----------|-----------------|-------|
| 1a: NACL bugs | 15 | | |
| 1b: RDS bugs | 20 | | |
| 1b: RDS Proxy completion | 15 | | |
| 2a: NodePool design | 20 | | |
| 2b: KEDA fixes | 15 | | |
| 3a: Root cause analysis | 10 | | |
| 3b: Remediation plan | 5 | | |
| **Total** | **100** | | |

Passing threshold: **70/100**
Senior hire threshold: **85/100**

---

## Task 1 — Terraform

### 1a: NACL Fixes (15 points)

**Bug 1 — Protected inbound postgres allows only node CIDR (5 pts)**

```hcl
# CORRECT FIX: Add rule 101 for pod CIDR
resource "aws_network_acl_rule" "protected_inbound_postgres_pods" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 101
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "100.64.0.0/16"  # pod CIDR — VPC CNI prefix delegation
  from_port      = 5432
  to_port        = 5432
}
```

**Bug 2 — Protected inbound redis allows only node CIDR (5 pts)**

```hcl
resource "aws_network_acl_rule" "protected_inbound_redis_pods" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 111
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "100.64.0.0/16"
  from_port      = 6379
  to_port        = 6379
}
```

**Bug 3 — Outbound ephemeral only covers node CIDR (5 pts)**

```hcl
resource "aws_network_acl_rule" "protected_outbound_ephemeral_pods" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 101
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "100.64.0.0/16"
  from_port      = 1024
  to_port        = 65535
}
```

**Why silent drops?** NACLs are stateless — return traffic must be explicitly allowed. Without the outbound ephemeral rule for `100.64.0.0/16`, the database returns TCP responses to pods that are silently dropped at the NACL. The pod sees a timeout (ETIMEDOUT), not a refused connection (ECONNREFUSED). This makes the bug non-obvious: `nc -zv` from a node succeeds; `nc -zv` from a pod times out.

**Scoring guide:**
- Full marks: identifies all 3 rules, explains why drops are silent (stateless NACL)
- Partial (8/15): finds the inbound rules but misses the outbound ephemeral gap
- Minimal (5/15): fixes inbound postgres only, no explanation

---

### 1b: RDS Module — Bugs Fixed (20 points)

**Bug 1 — Security Group circular dependency (7 pts)**

The `ingress` block in `aws_security_group.rds` references `aws_security_group.rds_proxy.id` inline, and the `egress` block in `aws_security_group.rds_proxy` references `aws_security_group.rds.id`. Terraform cannot resolve this during plan.

**Correct fix:** Remove cross-references from inline `ingress`/`egress` blocks. Create both SGs without cross-references, then add `aws_security_group_rule` resources:

```hcl
resource "aws_security_group" "rds" {
  name   = "${var.cluster_name}-rds-sg"
  vpc_id = var.vpc_id
  # No inline ingress — use aws_security_group_rule below
  egress {
    from_port   = 0; to_port = 0; protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds_proxy" {
  name   = "${var.cluster_name}-rds-proxy-sg"
  vpc_id = var.vpc_id
  # No inline egress — use aws_security_group_rule below
}

resource "aws_security_group_rule" "rds_from_proxy" {
  type                     = "ingress"
  from_port                = 5432; to_port = 5432; protocol = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.rds_proxy.id
}

resource "aws_security_group_rule" "rds_proxy_to_rds" {
  type                     = "egress"
  from_port                = 5432; to_port = 5432; protocol = "tcp"
  security_group_id        = aws_security_group.rds_proxy.id
  source_security_group_id = aws_security_group.rds.id
}
```

**Bug 2 — Missing pod CIDR ingress on RDS Proxy SG (7 pts)**

```hcl
resource "aws_security_group_rule" "rds_proxy_from_pods" {
  type              = "ingress"
  from_port         = 5432; to_port = 5432; protocol = "tcp"
  security_group_id = aws_security_group.rds_proxy.id
  cidr_blocks       = ["100.64.0.0/16"]
  description       = "PostgreSQL from EKS pods (VPC CNI prefix delegation)"
}
```

**Why:** With VPC CNI prefix delegation, pod traffic originates from `100.64.0.0/16`, not from the node IP. SG rules based on the node SG ID only match traffic from the node's primary ENI, not from pod ENIs. Without this CIDR rule, all pod→RDS Proxy connections are dropped at the SG.

**Bug 3 — RDS in wrong subnet tier (6 pts)**

```hcl
# WRONG
db_subnet_group_name = aws_db_subnet_group.web.name

# CORRECT: create subnet group from protected subnets
resource "aws_db_subnet_group" "protected" {
  name       = "${var.cluster_name}-rds-protected-subnet-group"
  subnet_ids = var.protected_subnet_ids
}

# And reference it:
db_subnet_group_name = aws_db_subnet_group.protected.name
```

**Why:** Web subnets have a route to the internet gateway. Placing RDS in web subnets exposes the database to potential inbound internet traffic (mitigated only by SG, not by network isolation). The defense-in-depth principle requires database services in subnets with no public route. Protected subnets have no default route — even if SG is misconfigured, the network layer still blocks ingress.

**Scoring guide:**
- Full marks: all 3 bugs found + explanations cover the *why*
- Partial (12/20): finds SG cycle and subnet bug, misses pod CIDR ingress
- Minimal (7/20): finds only the SG cycle

---

### 1b: RDS Proxy Completion (15 points)

**Correct completed resource:**

```hcl
resource "aws_db_proxy" "app" {
  name                   = "${var.cluster_name}-app-proxy"
  debug_logging          = false
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800            # 30 min: keeps PgBouncer-like long-lived connections
  require_tls            = true
  role_arn               = var.rds_proxy_role_arn
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]
  vpc_subnet_ids         = var.protected_subnet_ids  # MUST be protected, not web/app

  auth {
    auth_scheme = "SECRETS"
    description = "App DB credentials"
    iam_auth    = "DISABLED"               # App uses username/password via SecretsManager
    secret_arn  = var.db_secret_arn
  }
}

resource "aws_db_proxy_default_target_group" "app" {
  db_proxy_name = aws_db_proxy.app.name
  connection_pool_config {
    connection_borrow_timeout = 5          # 5s: fail fast, surface DB pressure to app
    max_connections_percent   = 100
  }
}
```

**Key decisions to look for in SOLUTION.md:**

| Decision | Correct answer | What wrong answers look like |
|----------|---------------|------------------------------|
| `vpc_subnet_ids` | `protected_subnet_ids` | web or app subnets — breaks subnet isolation |
| `idle_client_timeout` | 1800s (or any value with reasoning) | No justification provided |
| `connection_borrow_timeout` | 5s with "fail fast" reasoning | 0 or 120+ without explanation |
| `iam_auth` | `DISABLED` with reason (off-the-shelf app) | `REQUIRED` without noting app compatibility |

**Scoring guide:**
- Full marks: correct subnets + all fields completed + reasoning for each
- Partial (9/15): correct subnets and fields, no SOLUTION.md reasoning
- Minimal (5/15): fields filled but subnet is wrong

---

## Task 2 — Kubernetes

### 2a: NodePool Design (20 points)

**Reference solution for App NodePool:**

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: helios-ai-app
spec:
  template:
    metadata:
      labels:
        workload: app
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: helios-ai-default
      taints:
        - key: workload
          value: app
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["c5.xlarge","c5.2xlarge","c6i.xlarge","c6i.2xlarge",
                   "m5.xlarge","m5.2xlarge","m6i.xlarge","m6i.2xlarge"]
  limits:
    cpu: "80"
    memory: 160Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```

**Reference solution for DB NodePool:**

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: helios-ai-db
spec:
  template:
    metadata:
      labels:
        workload: db
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: helios-ai-default
      taints:
        - key: workload
          value: db
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]           # NEVER spot for stateful DB nodes
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["r5.xlarge","r5.2xlarge","r6i.xlarge","r6i.2xlarge",
                   "m5.2xlarge","m6i.2xlarge"]
  limits:
    cpu: "16"
    memory: 64Gi
  disruption:
    consolidationPolicy: WhenEmpty        # Never consolidate nodes with running DB pods
    consolidateAfter: Never
```

**Scoring guide:**

| Decision | Full marks | Partial | Zero |
|----------|-----------|---------|------|
| App: spot allowed | Yes + rationale (stateless, retry logic) | Yes, no rationale | No |
| DB: on-demand only | Yes + rationale (stateful, data loss risk) | Yes, no rationale | Uses spot for DB |
| App consolidation | WhenEmptyOrUnderutilized + reasoning | Present, no reasoning | Missing |
| DB consolidation | WhenEmpty or consolidateAfter:Never + reasoning | Present, no reasoning | Missing or wrong policy |
| Taint strategy | Both pools tainted, explains isolation purpose | Taints present | No taints |
| Instance families | c/m for app (CPU-intensive), r/m for DB (memory) | Reasonable choices | Random/inappropriate |

- Full marks (20): all decisions correct + explained in SOLUTION.md
- Good (14-19): decisions correct, some missing reasoning
- Partial (8-13): one pool wrong (e.g. spot on DB) but other correct
- Minimal (<8): both pools missing consolidation policy or spot on DB nodes

---

### 2b: KEDA ScaledObject Fixes (15 points, 3 pts each)

**Bug 1 — Missing fallback (3 pts)**

```yaml
fallback:
  failureThreshold: 3
  replicas: 5          # hold at safe minimum if Mimir is unreachable
```

A gateway with no fallback scales to 0 when the metrics backend is unavailable. This turns a monitoring outage into a service outage.

**Bug 2 — Wrong serverAddress x2 (3 pts)**

```yaml
serverAddress: http://mimir-svc.monitoring.svc.cluster.local:9009/prometheus
```

Both prometheus triggers have `https://prometheus.helios-ai.io`. The correct address is the in-cluster Mimir service. Using an external address: (a) adds external DNS + network roundtrip latency to every scaling decision, (b) may not be routable from within the cluster, (c) leaks internal metric data externally.

**Bug 3 — Threshold too high (3 pts)**

```yaml
threshold: "10"   # scale out when avg in-flight per pod > 10
```

Threshold `"1000"` means KEDA only adds a replica when total in-flight requests exceed 1000. At a pod capacity of ~10, the service would be severely overloaded before any scale-out occurs.

**Bug 4 — Malformed PromQL (3 pts)**

```yaml
query: histogram_quantile(0.99, rate(litellm_request_duration_seconds_bucket[5m]))
```

`histogram_quantile` requires a `rate()` over a time window as its second argument. Without `rate()`, it receives raw counter values, which grows monotonically and never produces a meaningful quantile.

**Bug 5 — CPU threshold 200% (3 pts)**

```yaml
value: "70"   # 70% CPU utilization
```

CPU utilization is expressed as a percentage of the container's CPU request. 200% is physically impossible for a single-core equivalent request and will never trigger. 70% is a common production threshold — high enough to avoid unnecessary scale-out, low enough to scale before saturation.

---

## Task 3 — Incident Investigation

### 3a: Root Cause Analysis (10 points)

**Root Cause 1 — NACL blocks pod-to-RDS traffic (4 pts)**

Evidence: Pod IP is `100.64.4.17` (from `kubectl describe`). NACL for protected subnets only allows `10.10.64.0/20`. The pod's IP is in `100.64.0.0/16` — no NACL rule permits this traffic. Result: TCP connection to RDS Proxy times out (`ETIMEDOUT`), not refused (`ECONNREFUSED`).

**Root Cause 2 — RDS Proxy in web subnets (3 pts)**

Evidence: `aws rds describe-db-proxies` shows `VpcSubnetIds: [subnet-0web1aaa, subnet-0web2bbb, subnet-0web3ccc]`. These are web-tier subnets (public-facing, IGW route). RDS Proxy should be in protected subnets. In this case the NACL is also protecting the wrong subnet (app NACL is fine; protected NACL blocks pods). The combination of wrong subnet + NACL creates the TCP timeout.

**Root Cause 3 — Redis TLS mismatch (3 pts)**

Evidence: `aws elasticache describe-replication-groups` shows `TransitEncryptionMode: required`. But `helios-api-configmap.yaml` has `REDIS_URL: redis://...` (plaintext scheme) and `REDIS_SSL: "false"`. The worker log shows `ECONNREFUSED` on the Redis URL — ElastiCache with `TransitEncryptionMode=required` rejects non-TLS connections at the TLS handshake, which manifests as a refused connection to the app.

**Fix:**
```yaml
REDIS_URL: "rediss://master.helios-ai-prod-valkey.abc.apse3.cache.amazonaws.com:6379"
REDIS_SSL: "true"
```

**Scoring guide:**
- Full marks: all 3 root causes identified with specific evidence citations
- Good (7-9): 2 root causes found, one missed or lacks evidence
- Partial (4-6): 1 root cause found
- Minimal (<4): correct intuition but no evidence cited

---

### 3b: Remediation Plan (5 points)

Look for these specific fixes:

**Fix 1:** Add NACL rules for `100.64.0.0/16` to the protected NACL (inbound 5432, 6379 + outbound 1024-65535)

**Fix 2:** Move RDS Proxy to `protected_subnet_ids` in Terraform

**Fix 3:** Update ConfigMap `REDIS_URL` to `rediss://` and `REDIS_SSL: "true"`, then `kubectl rollout restart deployment/helios-api`

**Scoring guide:**
- Full marks: all 3 fixes with correct implementation (YAML or Terraform snippet shown)
- Partial: fixes identified but implementation incomplete

---

## Red Flags (disqualifying patterns)

- RDS Proxy placed in `app_subnet_ids` instead of `protected_subnet_ids` — shows no understanding of tiered networking
- Spot instances for DB NodePool — data loss risk not understood
- KEDA fallback omitted or set to 0 — no understanding of dependency failure cascades
- Root cause analysis has no evidence citations — pattern matching without debugging methodology
- `terraform validate` fails — code not tested

## Green Flags (senior signal)

- Explains NACL statelessness as the reason for silent drops vs TCP resets
- Notes that pod CIDR (`100.64.0.0/16`) is distinct from node CIDR and explains why
- `consolidateAfter: Never` on DB pool with explicit reasoning about StatefulSet safety
- KEDA fallback value justified (e.g. "hold at 5 to maintain capacity during Mimir maintenance")
- Redis fix notes that `rediss://` vs `redis://` is a scheme change, not just a flag change
- Proposes monitoring/alerting as prevention (e.g. NACL change alert, Redis TLS drift detection)
