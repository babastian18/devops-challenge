# ==============================================================================
# Helios AI — RDS + RDS Proxy Module
#
# STATUS: INCOMPLETE + CONTAINS BUGS
#
# Your tasks:
#   1. Complete the RDS Proxy resource (marked TODO)
#   2. Fix all security group misconfigurations (marked BUG)
#   3. Add RDS TLS enforcement via parameter group
#   4. Justify each decision in your SOLUTION.md
# ==============================================================================

# ------------------------------------------------------------------------------
# Security Groups
# ------------------------------------------------------------------------------

# BUG 1: This SG references aws_security_group.rds_proxy inline,
# creating a circular dependency. Terraform will error on plan.
# Fix: break the cycle using aws_security_group_rule resources.
resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds-sg"
  description = "RDS PostgreSQL security group"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from RDS Proxy"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds_proxy.id] # BUG 1: circular ref
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-rds-sg" }
}

resource "aws_security_group" "rds_proxy" {
  name        = "${var.cluster_name}-rds-proxy-sg"
  description = "RDS Proxy security group"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS pods"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_sg_id]
    # BUG 2: Missing pod CIDR ingress.
    # EKS VPC CNI prefix delegation assigns pod IPs from 100.64.0.0/16.
    # Pods do NOT use the node SG for traffic originating from pod IPs.
    # Without this rule, all pod→RDS Proxy connections are silently dropped.
  }

  egress {
    description     = "PostgreSQL to RDS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds.id] # BUG 1: circular ref
  }

  tags = { Name = "${var.cluster_name}-rds-proxy-sg" }
}

# ------------------------------------------------------------------------------
# RDS Parameter Group — TLS enforcement
# TODO: Add a parameter group that sets rds.force_ssl = 1
# Without this, connections to RDS are accepted in plaintext.
# ------------------------------------------------------------------------------

# YOUR CODE HERE

# ------------------------------------------------------------------------------
# RDS Instance
# ------------------------------------------------------------------------------

resource "aws_db_instance" "app" {
  identifier        = "${var.cluster_name}-app"
  engine            = "postgres"
  engine_version    = "16.3"
  instance_class    = var.db_instance_class
  allocated_storage = 100
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "helios_app"
  username = var.db_username
  password = var.db_password

  # BUG 3: Wrong subnet group — uses web subnets instead of protected subnets.
  # RDS should never be in web subnets (public-facing tier).
  # Web subnets have an IGW route; protected subnets are intentionally isolated.
  db_subnet_group_name   = aws_db_subnet_group.web.name # BUG 3
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az               = true
  deletion_protection    = true
  skip_final_snapshot    = false
  final_snapshot_identifier = "${var.cluster_name}-app-final"

  backup_retention_period = 7
  backup_window           = "18:00-19:00"
  maintenance_window      = "sat:20:00-sat:21:00"

  # TODO: reference your parameter group here once created
  # parameter_group_name = ...

  tags = { Name = "${var.cluster_name}-app-rds" }
}

# BUG 3 continued: subnet group built from web subnets
resource "aws_db_subnet_group" "web" {
  name       = "${var.cluster_name}-rds-web-subnet-group"
  subnet_ids = var.web_subnet_ids # BUG 3: should be var.protected_subnet_ids

  tags = { Name = "${var.cluster_name}-rds-subnet-group" }
}

# ------------------------------------------------------------------------------
# RDS Proxy
# TODO: Complete this resource. Requirements:
#   - Must use protected_subnet_ids (not web or app)
#   - Auth: SecretsManager, IAM auth DISABLED (app uses username/password)
#   - connection_borrow_timeout: 5 seconds
#   - idle_client_timeout: 1800 seconds
#   - Attach the correct security group
# ------------------------------------------------------------------------------

resource "aws_db_proxy" "app" {
  name                   = "${var.cluster_name}-app-proxy"
  debug_logging          = false
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = # TODO
  require_tls            = true
  role_arn               = var.rds_proxy_role_arn
  vpc_security_group_ids = [] # TODO: which SG?
  vpc_subnet_ids         = [] # TODO: which subnets?

  auth {
    auth_scheme = "SECRETS"
    description = "App DB credentials"
    iam_auth    = # TODO: "DISABLED" or "REQUIRED"?
    secret_arn  = var.db_secret_arn
  }

  tags = { Name = "${var.cluster_name}-app-proxy" }
}

resource "aws_db_proxy_default_target_group" "app" {
  db_proxy_name = aws_db_proxy.app.name

  connection_pool_config {
    connection_borrow_timeout = # TODO
    max_connections_percent   = 100
  }
}

resource "aws_db_proxy_target" "app" {
  db_instance_identifier = aws_db_instance.app.identifier
  db_proxy_name          = aws_db_proxy.app.name
  target_group_name      = aws_db_proxy_default_target_group.app.name
}
