output "web_instance_ids" {
  description = "IDs of web EC2 instances"
  value       = aws_instance.web[*].id
}

output "web_public_ips" {
  description = "Public IPs of web instances"
  value       = aws_instance.web[*].public_ip
}

output "app_instance_ids" {
  description = "IDs of app EC2 instances"
  value       = aws_instance.app[*].id
}

output "app_public_ips" {
  description = "Public IPs of app instances"
  value       = aws_instance.app[*].public_ip
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.app_sg.id
}
