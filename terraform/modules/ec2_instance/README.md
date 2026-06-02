# EC2 Instance Module

A reusable Terraform module for provisioning enterprise-grade EC2 instances
with multi-OS support.

## Supported OS Types

| OS Type       | SSH/RDP User  | Ports Opened               | Web Server   |
|---------------|---------------|----------------------------|--------------|
| amazon_linux  | ec2-user      | 22 (SSH), 80 (HTTP)        | nginx        |
| ubuntu        | ubuntu        | 22 (SSH), 80 (HTTP)        | nginx        |
| redhat        | ec2-user      | 22 (SSH), 80 (HTTP)        | nginx        |
| windows       | Administrator | 3389 (RDP), 5985/6 (WinRM) | IIS          |

## Features

- **Security groups** with OS-appropriate ingress rules
- **Spot instance** support (configurable max price)
- **EBS encryption** with optional KMS key
- **IMDSv2 enforcement** (required)
- **Elastic IP** automatically assigned for Windows instances (WinRM needs static IP)
- **Comprehensive tagging** for Ansible dynamic inventory
- **EBS optimization** enabled by default
- **Detailed monitoring** on production environments

## Usage

```hcl
module "web_servers" {
  source = "./modules/ec2_instance"

  instance_name   = "web-server"
  os_type         = "amazon_linux"
  ami_id          = "ami-0abcdef1234567890"
  instance_type   = "t3.medium"
  instance_count  = 2
  volume_size     = 30
  role            = "web"
  environment     = "dev"
  vpc_id          = data.aws_vpc.default.id
  subnet_ids      = data.aws_subnets.default.ids
  ssh_public_key  = var.ssh_public_key
  project_name    = var.project_name
  common_tags     = var.common_tags
}
```

## Inputs

See `variables.tf` for the full list.

## Outputs

- `instance_ids` — List of EC2 instance IDs
- `public_ips` — Public IP addresses
- `private_ips` — Private IP addresses
- `admin_user` — Default admin username for the OS
- `os_type` — OS type identifier
- `security_group_id` — Security group ID
- `eip_addresses` — Elastic IPs (Windows only)