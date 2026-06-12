###############################################################################
# modules/ec2_instance/variables.tf
# Input variables for the reusable EC2 instance module
###############################################################################

variable "instance_name" {
  description = "Base name for the EC2 instance(s)"
  type        = string
}

variable "os_type" {
  description = "Operating system type (amazon_linux, ubuntu, redhat, windows)"
  type        = string
  validation {
    condition     = contains(["amazon_linux", "ubuntu", "redhat", "windows"], var.os_type)
    error_message = "os_type must be one of: amazon_linux, ubuntu, redhat, windows."
  }
}

variable "ami_id" {
  description = "AMI ID for the EC2 instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type (e.g., t3.micro, t3.medium, t3.large)"
  type        = string
  default     = "t3.micro"
}

variable "instance_count" {
  description = "Number of EC2 instances to create for this group"
  type        = number
  default     = 1
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "volume_type" {
  description = "Root EBS volume type"
  type        = string
  default     = "gp3"
}

variable "subnet_ids" {
  description = "List of subnet IDs for instance placement"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID for the security group"
  type        = string
}

variable "key_name" {
  description = "Name of an existing EC2 key pair to attach to instances"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key content for EC2 key pair (kept for backward compat)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "role" {
  description = "Instance role tag (web, app, db, etc.)"
  type        = string
  default     = "app"
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
    Owner     = "DevOps"
  }
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
  description = "Maximum spot price. Empty string = use on-demand pricing."
  type        = string
  default     = ""
}

variable "assign_public_ip" {
  description = "Whether to assign a public IP address to instances"
  type        = bool
  default     = true
}

variable "enable_volume_encryption" {
  description = "Enable EBS volume encryption"
  type        = bool
  default     = true
}

variable "kms_key_id" {
  description = "KMS key ID for EBS encryption (defaults to AWS managed key if empty)"
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "tf-ansible-demo"
}

variable "additional_sg_ids" {
  description = "Additional security group IDs to attach to instances"
  type        = list(string)
  default     = []
}

variable "user_data_script" {
  description = "Base64-encoded user data script for instance initialization"
  type        = string
  default     = ""
}

variable "winrm_password" {
  description = "Password for the WinRM local admin account (ansible_admin). Injected via TF_VAR_WINrm_password from GitHub Actions secrets."
  type        = string
  sensitive   = true
  default     = ""
}

variable "iam_instance_profile" {
  description = "IAM instance profile name to attach to EC2 instances (for CloudWatch Agent, etc.)"
  type        = string
  default     = ""
}