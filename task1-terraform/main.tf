terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "networking" {
  source = "./modules/networking"

  cluster_name       = var.cluster_name
  environment        = var.environment
  vpc_cidr           = "10.10.0.0/16"
  availability_zones = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]

  # These are passed to NACL resources inside the module
  vpc_id               = module.networking.vpc_id
  app_subnet_ids       = module.networking.app_subnet_ids
  protected_subnet_ids = module.networking.protected_subnet_ids
}

module "rds" {
  source = "./modules/rds"

  cluster_name         = var.cluster_name
  vpc_id               = module.networking.vpc_id
  eks_node_sg_id       = var.eks_node_sg_id
  web_subnet_ids       = module.networking.web_subnet_ids
  app_subnet_ids       = module.networking.app_subnet_ids
  protected_subnet_ids = module.networking.protected_subnet_ids
  db_username          = var.db_username
  db_password          = var.db_password
  db_secret_arn        = var.db_secret_arn
  rds_proxy_role_arn   = var.rds_proxy_role_arn
}

variable "aws_region"        { type = string; default = "ap-southeast-3" }
variable "cluster_name"      { type = string; default = "helios-ai-prod" }
variable "environment"       { type = string; default = "prod" }
variable "eks_node_sg_id"    { type = string; description = "EKS node security group ID" }
variable "db_username"       { type = string; default = "helios_app" }
variable "db_password"       { type = string; sensitive = true }
variable "db_secret_arn"     { type = string }
variable "rds_proxy_role_arn" { type = string }
