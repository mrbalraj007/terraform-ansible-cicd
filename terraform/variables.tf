###############################################################################
# terraform/variables.tf
# Root-level variables — user configures these via terraform.tfvars
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "tf-ansible-demo"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}


variable "allowed_ssh_cidr" {
  description = "CIDR blocks allowed for SSH (Linux) / RDP (Windows) access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_http_cidr" {
  description = "CIDR blocks allowed for HTTP/HTTPS access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "spot_max_price" {
  description = "Maximum spot price for all instances. Empty string = on-demand pricing. Set to \"0.016\" for t3.micro spot."
  type        = string
  default     = ""
}

variable "common_tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
    Owner     = "DevOps"
  }
}

variable "enable_volume_encryption" {
  description = "Enable EBS volume encryption for all instances"
  type        = bool
  default     = true
}

variable "winrm_password" {
  description = "Password for the Windows WinRM local admin account (ansible_admin). Injected via TF_VAR_WINRM_PASSWORD from GitHub Actions secrets."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tf_state_bucket" {
  description = "S3 bucket name for Terraform state (used as shared store for the deployer private key). Injected via TF_VAR_tf_state_bucket from GitHub Actions secrets."
  type        = string
  default     = ""
}

# ──── Server Definitions (THE core variable) ────────────────────────────────
# Users define their servers as a list of objects in terraform.tfvars:
#
# servers = [
#   {
#     name          = "web-server"
#     os_type       = "amazon_linux"
#     instance_type = "t3.medium"
#     count         = 2
#     volume_size   = 30
#     role          = "web"
#     environment   = "dev"           # optional, defaults to var.environment
#   },
#   {
#     name          = "app-server"
#     os_type       = "ubuntu"
#     instance_type = "t3.medium"
#     count         = 1
#     volume_size   = 50
#     role          = "app"
#   },
# ]
#
# os_type must be one of: amazon_linux, ubuntu, redhat, windows

variable "servers" {
  description = <<-EOT
    List of server group definitions. Each entry specifies an OS type, count,
    instance type, and role. The module creates that many EC2 instances
    with appropriate security groups, tags, and Ansible inventory metadata.
  EOT
  type = list(object({
    name          = string
    os_type       = string
    instance_type = optional(string, "t3.micro")
    count         = optional(number, 1)
    volume_size   = optional(number, 30)
    role          = optional(string, "app")
    environment   = optional(string, "") # falls back to var.environment
    spot_price    = optional(string, "") # falls back to var.spot_max_price
  }))

  validation {
    condition = alltrue([
      for s in var.servers : contains(["amazon_linux", "ubuntu", "redhat", "windows"], s.os_type)
    ])
    error_message = "Each server's os_type must be one of: amazon_linux, ubuntu, redhat, windows."
  }

  default = [
    {
      name          = "default-web"
      os_type       = "amazon_linux"
      instance_type = "t3.micro"
      count         = 1
      volume_size   = 30
      role          = "web"
    }
  ]
}