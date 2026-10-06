# ==============================================================================
# Helios AI — RDS + RDS Proxy Module
# ==============================================================================

# ------------------------------------------------------------------------------
# Security Groups
#
# Rules are standalone aws_security_group_rule resources: rds and rds_proxy
# reference each other, so inline rules would create a dependency cycle.
# Do not add inline ingress/egress blocks to these SGs — mixing inline and
# standalone rules makes Terraform overwrite them on every apply.
# ------------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds-sg"
  description = "RDS PostgreSQL security group"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.cluster_name}-rds-sg" }
}

resource "aws_security_group" "rds_proxy" {
  name        = "${var.cluster_name}-rds-proxy-sg"
  description = "RDS Proxy security group"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.cluster_name}-rds-proxy-sg" }
}

resource "aws_security_group_rule" "rds_ingress_from_proxy" {
  type                     = "ingress"
  description              = "PostgreSQL from RDS Proxy"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.rds_proxy.id
  protocol                 = "tcp"
  from_port                = 5432
  to_port                  = 5432
}

resource "aws_security_group_rule" "rds_proxy_ingress_from_nodes" {
  type                     = "ingress"
  description              = "PostgreSQL from EKS nodes"
  security_group_id        = aws_security_group.rds_proxy.id
  source_security_group_id = var.eks_node_sg_id
  protocol                 = "tcp"
  from_port                = 5432
  to_port                  = 5432
}

# Pod ENIs (VPC CNI custom networking) do not necessarily carry the node SG
resource "aws_security_group_rule" "rds_proxy_ingress_from_pods" {
  type              = "ingress"
  description       = "PostgreSQL from EKS pods"
  security_group_id = aws_security_group.rds_proxy.id
  cidr_blocks       = ["100.64.0.0/16"]
  protocol          = "tcp"
  from_port         = 5432
  to_port           = 5432
}

resource "aws_security_group_rule" "rds_proxy_egress_to_rds" {
  type                     = "egress"
  description              = "PostgreSQL to RDS"
  security_group_id        = aws_security_group.rds_proxy.id
  source_security_group_id = aws_security_group.rds.id
  protocol                 = "tcp"
  from_port                = 5432
  to_port                  = 5432
}

# ------------------------------------------------------------------------------
# RDS Parameter Group — TLS enforcement
# ------------------------------------------------------------------------------

resource "aws_db_parameter_group" "app" {
  name        = "${var.cluster_name}-postgres16"
  family      = "postgres16"
  description = "Helios app PostgreSQL 16 - enforce TLS"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = { Name = "${var.cluster_name}-postgres16" }
}

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

  db_subnet_group_name   = aws_db_subnet_group.protected.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.app.name

  multi_az                  = true
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.cluster_name}-app-final"

  backup_retention_period = 7
  backup_window           = "18:00-19:00"
  maintenance_window      = "sat:20:00-sat:21:00"

  tags = { Name = "${var.cluster_name}-app-rds" }
}

resource "aws_db_subnet_group" "protected" {
  name       = "${var.cluster_name}-rds-protected-subnet-group"
  subnet_ids = var.protected_subnet_ids

  tags = { Name = "${var.cluster_name}-rds-subnet-group" }
}

# ------------------------------------------------------------------------------
# RDS Proxy
# ------------------------------------------------------------------------------

resource "aws_db_proxy" "app" {
  name                   = "${var.cluster_name}-app-proxy"
  debug_logging          = false
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800
  require_tls            = true
  role_arn               = var.rds_proxy_role_arn
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]
  vpc_subnet_ids         = var.protected_subnet_ids

  auth {
    auth_scheme = "SECRETS"
    description = "App DB credentials"
    iam_auth    = "DISABLED"
    secret_arn  = var.db_secret_arn
  }

  tags = { Name = "${var.cluster_name}-app-proxy" }
}

resource "aws_db_proxy_default_target_group" "app" {
  db_proxy_name = aws_db_proxy.app.name

  connection_pool_config {
    connection_borrow_timeout = 5
    max_connections_percent   = 100
  }
}

resource "aws_db_proxy_target" "app" {
  db_instance_identifier = aws_db_instance.app.identifier
  db_proxy_name          = aws_db_proxy.app.name
  target_group_name      = aws_db_proxy_default_target_group.app.name
}
