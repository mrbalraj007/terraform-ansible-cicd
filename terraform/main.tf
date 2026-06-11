###############################################################################
# main.tf — Root Module
# Provisions multiple EC2 instance groups from the `servers` variable using
# the reusable ec2_instance module. Each group gets its own security group,
# key pair references, and OS-appropriate configuration.
#
# Ansible dynamic inventory discovers instances via tags:
#   - tag:OS_Type  → group (e.g., tag_OS_Type_ubuntu, tag_OS_Type_windows)
#   - tag:Role     → group (e.g., tag_Role_web, tag_Role_app)
#   - tag:Environment → group (e.g., tag_Environment_dev)
###############################################################################

terraform {
  required_version = ">= 1.5.0"

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

# ──── Data Sources ──────────────────────────────────────────────────────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ──── Locals ─────────────────────────────────────────────────────────────────

locals {
  # Base64-encoded Windows user_data script that configures WinRM for Ansible
  # The configure-winrm.ps1 script already includes <powershell> tags
  windows_userdata_b64 = base64encode(file("../scripts/configure-winrm.ps1"))

  # Key pair name derived from project and environment
  key_pair_name = "${var.project_name}-${var.environment}-deployer-key"

  # Common tags for key pair resources
  common_tags = merge(var.common_tags, {
    Project = var.project_name
  })
}

# ──── TLS Private Key (generated locally) ────────────────────────────────
# Generates an RSA 4096-bit key pair. The private key is saved to disk
# (scripts/<key_name>.pem) and used by Ansible for SSH/RDP access.
# The public key is passed to the aws_key_pair resource below.
resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ──── Key Pair (uploaded to AWS) ─────────────────────────────────────────
# Creates an AWS key pair using the public key from the TLS private key above.
# The private key is stored locally and must be kept secure.
resource "aws_key_pair" "deployer" {
  key_name   = local.key_pair_name
  public_key = tls_private_key.ec2_key.public_key_openssh

  tags = merge(local.common_tags, {
    Environment = var.environment
    Project     = var.project_name
  })
}

# ──── Local Private Key File ──────────────────────────────────────────────
# Saves the generated private key to disk so it can be used by Ansible
# (SSH for Linux, RDP password decryption for Windows).
resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ec2_key.private_key_pem
  filename        = "${path.module}/../scripts/${local.key_pair_name}.pem"
  file_permission = "0600"
}

# ──── Upload Private Key to S3 (for Ansible to retrieve) ───────────────────
# After apply, the generated private key is uploaded to the S3 state bucket
# under a "keys/" prefix. The Ansible workflow downloads it at runtime so
# no GitHub Secret for SSH_PRIVATE_KEY is required.
resource "null_resource" "upload_private_key" {
  # Run after the key pair and local file are created
  depends_on = [tls_private_key.ec2_key, local_sensitive_file.private_key]

  provisioner "local-exec" {
    command = "aws s3 cp '${path.module}/../scripts/${local.key_pair_name}.pem' 's3://${var.tf_state_bucket}/keys/${local.key_pair_name}.pem' --sse AES256"
  }

  triggers = {
    # Re-upload whenever the private key changes (new apply = new key)
    key_content = tls_private_key.ec2_key.private_key_pem
  }
}

# ──── EC2 Instance Groups (one module call per server definition) ───────────
# Each entry in var.servers creates a group of EC2 instances with matching
# OS, security group, tags, and optional spot pricing.

module "server_group" {
  source = "./modules/ec2_instance"

  for_each = {
    for idx, s in var.servers :
    "${s.role}-${s.os_type}-${idx}" => s
  }

  instance_name            = each.value.name
  os_type                  = each.value.os_type
  ami_id                   = local.ami_ids[each.value.os_type]
  instance_type            = each.value.instance_type
  instance_count           = each.value.count
  volume_size              = each.value.volume_size
  role                     = each.value.role
  environment              = each.value.environment != "" ? each.value.environment : var.environment
  vpc_id                   = data.aws_vpc.default.id
  subnet_ids               = data.aws_subnets.default.ids
  key_name                 = aws_key_pair.deployer.key_name
  spot_max_price           = each.value.spot_price != "" ? each.value.spot_price : var.spot_max_price
  project_name             = var.project_name
  common_tags              = var.common_tags
  allowed_ssh_cidr         = var.allowed_ssh_cidr
  allowed_http_cidr        = var.allowed_http_cidr
  enable_volume_encryption = var.enable_volume_encryption

  # Pass the WinRM bootstrap script only to Windows instances
  user_data_script = each.value.os_type == "windows" ? local.windows_userdata_b64 : ""
  winrm_password   = var.winrm_password
}