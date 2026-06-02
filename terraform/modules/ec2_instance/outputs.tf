###############################################################################
# modules/ec2_instance/outputs.tf
###############################################################################

output "instance_ids" {
  description = "IDs of the created EC2 instances"
  value       = aws_instance.this[*].id
}

output "public_ips" {
  description = "Public IP addresses of the instances"
  value       = aws_instance.this[*].public_ip
}

output "private_ips" {
  description = "Private IP addresses of the instances"
  value       = aws_instance.this[*].private_ip
}

output "public_dns" {
  description = "Public DNS names of the instances"
  value       = aws_instance.this[*].public_dns
}

output "security_group_id" {
  description = "ID of the security group created for this instance group"
  value       = aws_security_group.this.id
}

output "security_group_name" {
  description = "Name of the security group created for this instance group"
  value       = aws_security_group.this.name
}

output "admin_user" {
  description = "Default admin username for this OS type"
  value       = local.admin_user[var.os_type]
}

output "os_type" {
  description = "OS type identifier for Ansible inventory grouping"
  value       = var.os_type
}

output "instance_role" {
  description = "Role tag assigned to these instances"
  value       = var.role
}

output "eip_addresses" {
  description = "Elastic IP addresses (Windows instances only)"
  value       = try(aws_eip.this[*].public_ip, [])
}