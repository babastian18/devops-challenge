# ==============================================================================
# Helios AI — VPC & Networking Module
# This module is COMPLETE. Do not modify it.
# ==============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.cluster_name}-vpc"
    Environment = var.environment
  }
}

# ------------------------------------------------------------------------------
# Subnets — three tiers
# web:       public-facing, NAT GW, load balancers
# app:       EKS nodes, application workloads
# protected: databases, caches, proxies — NO direct internet route
# ------------------------------------------------------------------------------

resource "aws_subnet" "web" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                     = "${var.cluster_name}-web-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
    Tier                     = "web"
  }
}

resource "aws_subnet" "app" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 4)
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                              = "${var.cluster_name}-app-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
    Tier                              = "app"
  }
}

resource "aws_subnet" "protected" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.cluster_name}-protected-${count.index + 1}"
    Tier = "protected"
  }
}

# ------------------------------------------------------------------------------
# Internet Gateway + NAT Gateway
# ------------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

resource "aws_eip" "nat" {
  count  = length(var.availability_zones)
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nat-eip-${count.index + 1}" }
}

resource "aws_nat_gateway" "main" {
  count         = length(var.availability_zones)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.web[count.index].id
  tags          = { Name = "${var.cluster_name}-nat-${count.index + 1}" }
  depends_on    = [aws_internet_gateway.main]
}

# ------------------------------------------------------------------------------
# Route Tables
# ------------------------------------------------------------------------------

resource "aws_route_table" "web" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.cluster_name}-rt-web" }
}

resource "aws_route_table" "app" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  tags = { Name = "${var.cluster_name}-rt-app-${count.index + 1}" }
}

resource "aws_route_table" "protected" {
  vpc_id = aws_vpc.main.id
  # No default route — protected subnets are intentionally isolated
  tags = { Name = "${var.cluster_name}-rt-protected" }
}

resource "aws_route_table_association" "web" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.web[count.index].id
  route_table_id = aws_route_table.web.id
}

resource "aws_route_table_association" "app" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

resource "aws_route_table_association" "protected" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.protected[count.index].id
  route_table_id = aws_route_table.protected.id
}
