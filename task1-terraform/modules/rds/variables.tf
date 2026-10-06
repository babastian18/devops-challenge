variable "cluster_name" { type = string }
variable "vpc_id" { type = string }
variable "eks_node_sg_id" { type = string }
variable "web_subnet_ids" { type = list(string) }
variable "app_subnet_ids" { type = list(string) }
variable "protected_subnet_ids" { type = list(string) }

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "db_username" { type = string }

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_secret_arn" {
  type        = string
  description = "SecretsManager secret ARN for RDS Proxy auth"
}

variable "rds_proxy_role_arn" {
  type        = string
  description = "IAM role ARN for RDS Proxy to access SecretsManager"
}
