output "rds_proxy_endpoint" {
  value       = aws_db_proxy.app.endpoint
  description = "RDS Proxy endpoint — use this in application connection strings"
}

output "rds_instance_id" {
  value = aws_db_instance.app.identifier
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "rds_proxy_sg_id" {
  value = aws_security_group.rds_proxy.id
}
