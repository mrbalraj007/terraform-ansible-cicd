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

  backend "s3" {
    bucket = "terraform-ansible-cicd" # Replace with your globally unique bucket name
    key    = "terraform-ansible/terraform.tfstate"
    region = "us-east-1"
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
  windows_userdata_b64 = base64encode(<<-EOWIN
<powershell>
${file("../scripts/configure-winrm.ps1")}
</powershell>
EOWIN
  )

  # Key pair name derived from project and environment
  key_pair_name = "${var.project_name}-${var.environment}-deployer-key"
}

# ──── Key Pair (created by Terraform — public key from GitHub Secret) ─────
# Creates an AWS key pair using the public key content passed via TF_VAR_ssh_public_key.
# The private key is stored in GitHub Secrets (SSH_PRIVATE_KEY) and used by Ansible.
resource "aws_key_pair" "deployer" {
  key_name   = local.key_pair_name
  public_key = var.ssh_public_key

  tags = merge(var.common_tags, {
    Environment = var.environment
    Project     = var.project_name
  })
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
}