# Helios AI — DevOps Engineer Take-Home Challenge

> **Time budget:** 4–6 hours  
> **Level:** Mid-to-Senior DevOps Engineer (3+ years)  
> **Stack:** AWS EKS, Terraform, Karpenter, KEDA, ElastiCache, RDS

---

## Overview

Helios AI runs a production AI platform on AWS (`ap-southeast-3`). The platform serves LLM inference, RAG pipelines, and async job processing at scale. Your challenge is to extend and debug real infrastructure artifacts from this platform across three tasks.

This is not a quiz. There are no trick questions. We want to see how you think, what you notice, and how you communicate your reasoning — not just whether you can produce syntactically correct HCL.

---

## Repository Structure

```
.
├── task1-terraform/          # Task 1: Terraform infrastructure
│   ├── main.tf               # Root module — do not modify
│   └── modules/
│       ├── networking/       # VPC, subnets, route tables, NACLs
│       └── rds/              # RDS PostgreSQL + RDS Proxy + Security Groups
│
├── task2-k8s/                # Task 2: Kubernetes / GitOps
│   ├── nodepools/
│   │   ├── nodeclass.yaml    # Karpenter NodeClass — complete, do not modify
│   │   └── nodepools.yaml    # Your NodePool design goes here
│   └── scaledobjects/
│       └── llm-gateway-scaledobject.yaml  # Broken KEDA config — fix it
│
├── task3-incident/           # Task 3: Incident investigation
│   ├── logs/
│   │   ├── application.log            # App error logs from the incident
│   │   └── kubectl-and-aws-output.txt # Diagnostic output
│   └── manifests/
│       ├── helios-api-configmap.yaml  # App configuration
│       └── helios-api-deployment.yaml # App deployment spec
│
└── SOLUTION.md               # Your answers, reasoning, and fixes (create this)
```

---

## Task 1 — Terraform: RDS + Networking (estimated 2 hours)

### Context

The networking module (`task1-terraform/modules/networking/`) is complete and correct. It creates a three-tier VPC:

| Tier | Purpose | Subnets |
|------|---------|---------|
| `web` | Public-facing, NAT Gateway, load balancers | `10.10.0.0/20`, `10.10.16.0/20`, `10.10.32.0/20` |
| `app` | EKS nodes, application workloads | `10.10.64.0/20`, `10.10.80.0/20`, `10.10.96.0/20` |
| `protected` | Databases, caches, proxies — no internet route | `10.10.128.0/20`, `10.10.144.0/20`, `10.10.160.0/20` |

EKS is deployed with **VPC CNI prefix delegation**. Pod IPs are assigned from `100.64.0.0/16` — they do not use the node subnet CIDR.

### Your Tasks

**1a — Fix `modules/networking/nacl.tf`**

The protected subnet NACL has bugs that silently block all pod-to-database traffic. Find and fix them. Explain why they cause silent drops (not TCP resets).

**1b — Fix and complete `modules/rds/main.tf`**

This module has three bugs and two incomplete sections:

- **Bugs to fix:** Find all misconfigurations. Each is marked with a `BUG` comment.
- **TODO: RDS Parameter Group** — add an `aws_db_parameter_group` that enforces TLS on the RDS instance. Reference it from `aws_db_instance.app`.
- **TODO: RDS Proxy** — complete the `aws_db_proxy.app` resource. Fill in all `# TODO` fields with the correct values. Justify your choices in `SOLUTION.md`.

### Validation

```bash
cd task1-terraform
terraform init
terraform validate
```

`terraform validate` must pass with zero errors on your final submission.

---

## Task 2 — Kubernetes: Karpenter + KEDA (estimated 2 hours)

### Context

The Helios AI LLM Gateway runs on EKS with Karpenter for node provisioning and KEDA for workload autoscaling. Mimir (metrics backend) runs in-cluster at:

```
http://mimir-svc.monitoring.svc.cluster.local:9009/prometheus
```

LiteLLM exposes Prometheus metrics including `litellm_requests_in_progress` and `litellm_request_duration_seconds_bucket`.

### Your Tasks

**2a — Design `task2-k8s/nodepools/nodepools.yaml`**

Design two Karpenter NodePools using the requirements in the file. The `NodeClass` (`nodeclass.yaml`) is already complete — reference it from both pools.

Your design decisions to document in `SOLUTION.md`:
- Instance family selection and reasoning
- Spot vs on-demand strategy per workload type
- Disruption / consolidation policy and why they differ between pools
- How taints + tolerations enforce workload isolation

**2b — Fix `task2-k8s/scaledobjects/llm-gateway-scaledobject.yaml`**

This ScaledObject has 5 bugs. Find and fix all of them. For each fix, write one sentence in `SOLUTION.md` explaining the impact of the original bug.

### Validation

```bash
kubectl apply --dry-run=client -f task2-k8s/nodepools/nodepools.yaml
kubectl apply --dry-run=client -f task2-k8s/scaledobjects/llm-gateway-scaledobject.yaml
```

Both must apply cleanly (assuming Karpenter and KEDA CRDs are installed).

---

## Task 3 — Incident Investigation (estimated 1.5 hours)

### Scenario

**Alert received at 14:32 UTC:** `helios-ai` namespace is fully degraded. All API pods returning 503. Worker pods idle. LLM gateway reporting upstream connection failures.

The on-call engineer ran a series of diagnostic commands. The outputs are in `task3-incident/logs/kubectl-and-aws-output.txt`.

### Your Tasks

**3a — Root cause analysis**

Identify all root causes. There are multiple, and they are independent — fixing one will not fix the others. For each root cause:

- State what is failing and why
- Cite the specific evidence (log line, NACL rule, AWS CLI output) that led you to the conclusion

**3b — Remediation plan**

For each root cause, write the exact fix:
- If it's a Terraform change: show the corrected resource block
- If it's a manifest change: show the corrected YAML
- If it's an AWS CLI command: write the command

**3c — Prevention**

For each issue, propose one change to prevent recurrence. Think: IaC enforcement, CI validation, monitoring/alerting.

---

## Submission

1. **Fork this repository** to your own GitHub account (or create a new private repo)
2. **Create `SOLUTION.md`** at the repo root — your written answers go here
3. **Commit all file changes** — modified Terraform files, fixed K8s manifests, your NodePool design
4. **Share the repo link** with your interviewer

### SOLUTION.md structure

```markdown
## Task 1 — Terraform

### 1a: NACL Fixes
[your answer]

### 1b: RDS Module — Bugs Fixed
[your answer]

### 1b: RDS Proxy — Design Decisions
[your answer]

## Task 2 — Kubernetes

### 2a: NodePool Design Decisions
[your answer]

### 2b: KEDA ScaledObject — Bugs Fixed
[your answer]

## Task 3 — Incident

### 3a: Root Cause Analysis
[your answer]

### 3b: Remediation Plan
[your answer]

### 3c: Prevention
[your answer]
```

---

## Evaluation Criteria

| Area | Weight | What we look for |
|------|--------|-----------------|
| **Correctness** | 40% | Bugs identified and fixed accurately; Terraform validates; manifests apply cleanly |
| **Reasoning quality** | 35% | Clear explanation of *why*, not just *what*. Subnet placement reasoning, NACL behavior, KEDA fallback rationale |
| **Production-readiness** | 15% | TLS enforcement, correct subnet isolation, safe disruption policies for stateful workloads |
| **Communication** | 10% | SOLUTION.md is clear and structured. Would pass a PR review. |

---

## Notes

- You do **not** need a live AWS account or EKS cluster. All tasks are design + config only.
- `terraform validate` requires Terraform >= 1.6. Install via [tfenv](https://github.com/tfutils/tfenv) if needed.
- `kubectl --dry-run=client` requires `kubectl` with Karpenter and KEDA CRDs available, or you can validate the YAML structure manually.
- If you're unsure about a decision, state your assumption and proceed. We prefer a documented assumption over an unanswered question.
- Do not use AI tools to generate your SOLUTION.md. We'll ask you to walk through your reasoning in the follow-up interview.
