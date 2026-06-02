variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "tf-ansible-demo"
}

variable "environment" {
  description = "Environment (dev / staging / prod)"
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "web_instance_count" {
  description = "Number of web-tier EC2 instances"
  type        = number
  default     = 1
}

variable "app_instance_count" {
  description = "Number of app-tier EC2 instances"
  type        = number
  default     = 1
}

variable "ssh_public_key" {
  description = "SSH public key content — stored as GitHub Secret SSH_PUBLIC_KEY"
  type        = string
  sensitive   = true
}

variable "allowed_ssh_cidr" {
  description = "CIDR blocks allowed for SSH (GitHub-hosted runner IPs or 0.0.0.0/0 for simplicity)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "app_port" {
  description = "Port the application server listens on"
  type        = number
  default     = 8080
}

variable "spot_max_price" {
  description = "Maximum spot price (empty string = on-demand price). Set to \"0.016\" for t3.micro spot."
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
