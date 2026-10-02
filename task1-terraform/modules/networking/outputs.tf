output "vpc_id" {
  value = aws_vpc.main.id
}

output "web_subnet_ids" {
  value = aws_subnet.web[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "protected_subnet_ids" {
  value = aws_subnet.protected[*].id
}
