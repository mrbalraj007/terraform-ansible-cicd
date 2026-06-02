###############################################################################
# modules/ec2_instance/main.tf
# Enterprise-grade reusable EC2 instance module supporting multi-OS
###############################################################################

locals {
  # ── OS-specific SSH/RDP user ─────────────────────────────────────────────
  admin_user = {
    amazon_linux = "ec2-user"
    ubuntu       = "ubuntu"
    redhat       = "ec2-user"
    windows      = "Administrator"
  }

  # ── OS-specific ports ────────────────────────────────────────────────────
  ingress_rules = {
    amazon_linux = [
      { description = "SSH", port = 22, protocol = "tcp" },
      { description = "HTTP", port = 80, protocol = "tcp" },
    ]
    ubuntu = [
      { description = "SSH", port = 22, protocol = "tcp" },
      { description = "HTTP", port = 80, protocol = "tcp" },
    ]
    redhat = [
      { description = "SSH", port = 22, protocol = "tcp" },
      { description = "HTTP", port = 80, protocol = "tcp" },
    ]
    windows = [
      { description = "RDP", port = 3389, protocol = "tcp" },
      { description = "WinRM-HTTP", port = 5985, protocol = "tcp" },
      { description = "WinRM-HTTPS", port = 5986, protocol = "tcp" },
      { description = "HTTP", port = 80, protocol = "tcp" },
      { description = "HTTPS", port = 443, protocol = "tcp" },
    ]
  }

  # ── Effective spot config ────────────────────────────────────────────────
  use_spot = var.spot_max_price != "" && var.spot_max_price != null

  # ── Security group name ──────────────────────────────────────────────────
  sg_name = "${var.project_name}-${var.environment}-${var.role}-${var.os_type}-sg"
}

# ──── Security Group ───────────────────────────────────────────────────────
resource "aws_security_group" "this" {
  name        = local.sg_name
  description = "Security group for ${var.instance_name} (${var.os_type}) - ${var.environment}"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = local.ingress_rules[var.os_type]
    content {
      description = ingress.value.description
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.port == 22 || ingress.value.port == 3389 ? var.allowed_ssh_cidr : var.allowed_http_cidr
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name        = local.sg_name
    Environment = var.environment
    Project     = var.project_name
    OS_Type     = var.os_type
    Role        = var.role
  })
}

# ──── SSH/RDP Key Pair (name passed from root — key created by root module) ──

# ──── EC2 Instances ────────────────────────────────────────────────────────
resource "aws_instance" "this" {
  count = var.instance_count

  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids      = concat([aws_security_group.this.id], var.additional_sg_ids)
  associate_public_ip_address = var.assign_public_ip
  user_data_base64            = var.user_data_script != "" ? var.user_data_script : null

  # ── Spot instance (optional) ─────────────────────────────────────────────
  dynamic "instance_market_options" {
    for_each = local.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price                      = var.spot_max_price
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

  # ── Root block device ────────────────────────────────────────────────────
  root_block_device {
    volume_size           = var.volume_size
    volume_type           = var.volume_type
    delete_on_termination = true
    encrypted             = var.enable_volume_encryption
    kms_key_id            = var.enable_volume_encryption && var.kms_key_id != "" ? var.kms_key_id : null
  }

  # ── Metadata options (IMDSv2 enforcement) ────────────────────────────────
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # ── Credit specification (t2/t3 unlimited) ───────────────────────────────
  dynamic "credit_specification" {
    for_each = can(regex("^t[23]\\.", var.instance_type)) ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  # ── EBS-optimized (auto for most types, explicit for legacy) ─────────────
  ebs_optimized = true

  # ── Monitoring ───────────────────────────────────────────────────────────
  monitoring = var.environment == "prod" ? true : false

  tags = merge(var.common_tags, {
    Name        = "${var.instance_name}-${var.environment}-${count.index + 1}"
    Role        = var.role
    OS_Type     = var.os_type
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
  })
}

# ──── Elastic IP (Windows needs static IP for WinRM trust) ─────────────────
resource "aws_eip" "this" {
  count    = var.os_type == "windows" && var.assign_public_ip ? var.instance_count : 0
  domain   = "vpc"
  instance = aws_instance.this[count.index].id

  tags = merge(var.common_tags, {
    Name        = "${var.instance_name}-${var.environment}-${count.index + 1}-eip"
    Environment = var.environment
    Project     = var.project_name
    OS_Type     = var.os_type
  })
}