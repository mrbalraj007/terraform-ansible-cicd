###############################################################################
# terraform.tfvars
# Define your server inventory here. Each entry creates one group of EC2
# instances with matching OS, security group, and Ansible inventory tags.
# The pipeline reads this file during `terraform plan`.
#################################################################################

aws_region     = "us-east-1"
project_name   = "tf-ansible-demo"
environment    = "dev"
spot_max_price = "0.016"

# ──── Server Definitions ────────────────────────────────────────────────────
# os_type options: amazon_linux, ubuntu, redhat, windows
# role options:    web, app, db, bastion, monitoring, etc.
#
# Fields:
#   name          — Display name for the instance group
#   os_type       — Operating system type (determines AMI, admin user, ports)
#   instance_type — AWS EC2 instance class
#   count         — Number of identical instances in this group
#   volume_size   — Root EBS volume size in GB
#   role          — Application role (used for Ansible grouping via tag:Role)
#   environment   — (optional) Override the default environment
#   spot_price    — (optional) Override the default spot price; "" = on-demand

servers = [
  {
    name          = "web-server"
    os_type       = "amazon_linux"
    instance_type = "t3.micro"
    count         = 1
    volume_size   = 30
    role          = "web"
  },
  {
    name          = "app-server"
    os_type       = "ubuntu"
    instance_type = "t3.micro"
    count         = 1
    volume_size   = 30
    role          = "app"
  },
  {
    name          = "win-server"
    os_type       = "windows"
    instance_type = "t3.micro"
    count         = 1
    volume_size   = 30
    role          = "app"
  },
]

# ssh_public_key is injected via GitHub Secret TF_VAR_ssh_public_key — do NOT put it here