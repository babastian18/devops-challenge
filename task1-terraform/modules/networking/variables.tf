variable "cluster_name" {
  type        = string
  description = "EKS cluster name, used for resource naming and tags"
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. prod, staging)"
}

variable "vpc_cidr" {
  type        = string
  description = "Primary VPC CIDR block"
}

variable "availability_zones" {
  type        = list(string)
  description = "List of AZs to deploy subnets into"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID (used by NACL resources)"
}

variable "app_subnet_ids" {
  type        = list(string)
  description = "IDs of app-tier subnets"
}

variable "protected_subnet_ids" {
  type        = list(string)
  description = "IDs of protected-tier subnets"
}
