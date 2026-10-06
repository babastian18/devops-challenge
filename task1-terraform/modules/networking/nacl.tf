# ==============================================================================
# Helios AI — Network ACLs
#
# BUG NOTICE: This NACL configuration has deliberate issues.
# Your task: identify and fix all problems.

# ==============================================================================

# ------------------------------------------------------------------------------
# App Subnet NACL — controls traffic in/out of EKS node subnets
# Pod CIDR for this cluster: 100.64.0.0/16 (VPC CNI custom networking)
# Node CIDR: 10.10.64.0/18 (app subnets 10.10.64.0/20, 10.10.80.0/20, 10.10.96.0/20)
# ------------------------------------------------------------------------------

resource "aws_network_acl" "app" {
  vpc_id     = var.vpc_id
  subnet_ids = var.app_subnet_ids

  tags = { Name = "${var.cluster_name}-nacl-app" }
}

# Allow inbound from internet (ALB health checks, user traffic via NLB)
resource "aws_network_acl_rule" "app_inbound_https" {
  network_acl_id = aws_network_acl.app.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

# Allow inbound ephemeral ports (return traffic)
resource "aws_network_acl_rule" "app_inbound_ephemeral" {
  network_acl_id = aws_network_acl.app.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# Allow all outbound
resource "aws_network_acl_rule" "app_outbound_all" {
  network_acl_id = aws_network_acl.app.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

# ------------------------------------------------------------------------------
# Protected Subnet NACL — only node/pod CIDRs should reach databases
# ------------------------------------------------------------------------------

locals {
  app_cidr       = "10.10.64.0/18"  # app subnets, all 3 AZs
  pod_cidr       = "100.64.0.0/16"  # VPC CNI custom networking pod IPs
  protected_cidr = "10.10.128.0/18" # protected subnets, all 3 AZs
}

resource "aws_network_acl" "protected" {
  vpc_id     = var.vpc_id
  subnet_ids = var.protected_subnet_ids

  tags = { Name = "${var.cluster_name}-nacl-protected" }
}

# BUG 1: Only allows traffic from node CIDR — pods use a different CIDR
# EKS with VPC CNI prefix delegation assigns pods IPs from 100.64.0.0/16
# This rule blocks all pod-originated traffic to RDS/ElastiCache

resource "aws_network_acl_rule" "protected_inbound_postgres" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.app_cidr
  from_port      = 5432
  to_port        = 5432
}

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

resource "aws_network_acl_rule" "protected_inbound_redis" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.app_cidr
  from_port      = 6379
  to_port        = 6379
}

resource "aws_network_acl_rule" "protected_inbound_redis_pods" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 111
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.pod_cidr
  from_port      = 6379
  to_port        = 6379
}

# RDS Proxy -> RDS across protected subnets (cross-AZ)
resource "aws_network_acl_rule" "protected_inbound_postgres_intra" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 120
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.protected_cidr
  from_port      = 5432
  to_port        = 5432
}

# Valkey replication across protected subnets (cross-AZ)
resource "aws_network_acl_rule" "protected_inbound_redis_intra" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 121
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.protected_cidr
  from_port      = 6379
  to_port        = 6379
}

# Replies to connections initiated inside the protected tier
resource "aws_network_acl_rule" "protected_inbound_ephemeral_intra" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 130
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.protected_cidr
  from_port      = 1024
  to_port        = 65535
}

# ---------------- Egress ----------------

resource "aws_network_acl_rule" "protected_outbound_ephemeral" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.app_cidr
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "protected_outbound_ephemeral_pods" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 101
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.pod_cidr
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "protected_outbound_ephemeral_intra" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 110
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.protected_cidr
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "protected_outbound_postgres_intra" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 120
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.protected_cidr
  from_port      = 5432
  to_port        = 5432
}

resource "aws_network_acl_rule" "protected_outbound_redis_intra" {
  network_acl_id = aws_network_acl.protected.id
  rule_number    = 121
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.protected_cidr
  from_port      = 6379
  to_port        = 6379
}
