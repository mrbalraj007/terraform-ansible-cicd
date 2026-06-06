# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Enterprise Multi-OS Provisioning & Configuration** — Provisions Windows, Ubuntu, Amazon Linux, and Red Hat EC2 instances from a single `terraform.tfvars` inventory file, then automatically configures each OS with the correct Ansible playbook. The full CI/CD pipeline runs on GitHub Actions with OIDC authentication.

## Key Architecture

```
terraform.tfvars (server list) → Terraform (EC2 + SG + tags) → Ansible (dynamic inventory by OS tag → OS-specific playbook)
```

- **Terraform** — Root module in `terraform/` iterates over `var.servers` using `for_each`, calling the reusable `terraform/modules/ec2_instance/` module per server group. AMI lookups are centralized in `amis.tf`.
- **Ansible** — AWS EC2 dynamic inventory (`ansible/aws_ec2.yml`) discovers instances by tags. Playbooks are routed by OS type group (`tag_OS_Type_*`). The master orchestrator `ansible/playbooks/site.yml` delegates to OS-specific playbooks.
- **GitHub Actions** — Three reusable workflows in `.github/workflows/`: Terraform provision (plan/apply/destroy), Ansible configure (multi-OS), and a combined full CI/CD pipeline. Secrets (`AWS_IAM_ROLE_ARN`, `SSH_PUBLIC_KEY`, `SSH_PRIVATE_KEY`) are managed at the repo level.

## Commands

### Terraform

```bash
# Initialize (after bootstrap)
cd terraform && terraform init

# Validate
cd terraform && terraform validate

# Format check
cd terraform && terraform fmt -check -recursive

# Plan
cd terraform && terraform plan -var-file="terraform.tfvars"

# Apply
cd terraform && terraform apply -var-file="terraform.tfvars" -auto-approve

# Destroy
cd terraform && terraform destroy -var-file="terraform.tfvars" -auto-approve

# Plan with SSH key override (for dev/testing)
cd terraform && TF_VAR_ssh_public_key="$(cat ../scripts/keys/deployer_key.pub)" terraform plan -var-file="terraform.tfvars"
```

### Ansible

```bash
# Install Ansible collections
cd ansible && ansible-galaxy collection install -r requirements.yml

# Test dynamic inventory
cd ansible && ansible-inventory -i aws_ec2.yml --graph
cd ansible && ansible-inventory -i aws_ec2.yml --list | python3 -m json.tool

# Run playbook (all hosts)
cd ansible && ansible-playbook -i aws_ec2.yml playbooks/site.yml --private-key ~/.ssh/deployer_key

# Run playbook (limit to specific OS)
cd ansible && ansible-playbook -i aws_ec2.yml playbooks/site.yml --private-key ~/.ssh/deployer_key --limit tag_OS_Type_ubuntu

# Test connectivity
cd ansible && ansible tag_OS_Type_ubuntu -i aws_ec2.yml -m ping --private-key ~/.ssh/deployer_key
cd ansible && ansible tag_OS_Type_windows -i aws_ec2.yml -m ansible.windows.win_ping
```

### Local Setup Scripts

```bash
# Step 1: Generate SSH keys and upload to GitHub Secrets
./scripts/01.generate-ssh-keys.sh

# Step 2: Create IAM Role + OIDC provider for GitHub Actions
./scripts/02.setup-aws-oidc.sh

# Step 3: Create S3 bucket for Terraform remote state
./scripts/03.bootstrap.sh

# Tear down OIDC
./scripts/04.delete-aws-oidc.sh
```

### GitHub Actions (manual triggers)

```bash
# Full pipeline
gh workflow run "3 - Full CI/CD Pipeline (Provision + Configure)" --ref main -f environment=dev

# Destroy
gh workflow run "1 - Terraform Provision Infrastructure" --ref main -f action=destroy
```

## Important Design Details

### Terraform

- **Root module** (`terraform/main.tf`): Creates a single `aws_key_pair` from `var.ssh_public_key` (injected via GitHub Secret `TF_VAR_ssh_public_key`), then iterates `var.servers` with `for_each` calling the `ec2_instance` module.
- **Server definitions** (`terraform/terraform.tfvars`): A list of objects with fields: `name`, `os_type`, `instance_type`, `count`, `volume_size`, `role`, `environment` (optional), `spot_price` (optional). `os_type` must be one of: `amazon_linux`, `ubuntu`, `redhat`, `windows`.
- **AMI lookups** (`terraform/amis.tf`): Uses `data.aws_ami` with `most_recent = true` for each OS. Sources: Amazon (Amazon Linux, Windows), Canonical (099720109477 for Ubuntu), Red Hat (309956199498 for RHEL).
- **Module** (`terraform/modules/ec2_instance/`): Creates per-group security groups (SSH for Linux, RDP+WinRM+HTTP for Windows), EC2 instances with IMDSv2 enforcement, EBS encryption, optional spot pricing. OS-specific admin users: `ec2-user` (Amazon Linux/RHEL), `ubuntu`, `Administrator` (Windows).
- **Outputs** (`terraform/outputs.tf`): Includes `server_groups` (per-group map), flat lists (`all_public_ips`, etc.), OS-specific IPs, `admin_user_map` (IP → username), and `deployment_summary`.
- **State backend**: S3 bucket `terraform-ansible-cicd` in `us-east-1`. The bucket is created by `scripts/03.bootstrap.sh`.
- **Windows user_data**: Passes `scripts/configure-winrm.ps1` as base64-encoded PowerShell script only for Windows instances.

### Ansible

- **Dynamic inventory** (`ansible/aws_ec2.yml`): Uses `amazon.aws.aws_ec2` plugin. Filters on `tag:Project=tf-ansible-demo` and `tag:ManagedBy=Terraform`. Creates groups from `tags.Role`, `tags.OS_Type`, `tags.Environment`, and `instance_type`.
- **Group vars**: OS-specific connection parameters in `ansible/group_vars/tag_OS_Type_*.yml` (SSH user for Linux, WinRM transport for Windows). `ansible/group_vars/all.yml` has global variables.
- **site.yml** (master orchestrator): Routes to OS-specific playbooks by targeting `tag_OS_Type_*` groups. Linux plays use the `common` role; Windows uses `windows_common`.
- **OS-specific playbooks** handle: package management (dnf/apt/chocolatey), timezone, firewall (UFW/SELinux/Windows Firewall), web server (nginx for Linux, IIS for Windows), web content deployment.
- **Common role** (`ansible/roles/common/`): OS-agnostic tasks for package updates, timezone, MOTD. Handles the Amazon Linux 2023 `curl` vs `curl-minimal` conflict.
- **WinRM**: Windows instances use a self-signed cert + HTTPS (port 5986) with basic auth. `scripts/configure-winrm.ps1` runs at boot via user_data. The Ansible pipeline polls for WinRM readiness and retrieves admin passwords from EC2.

### CI/CD Pipeline

- **01-terraform-provision.yml**: Plan (formats check + validate + `terraform plan`), Apply (applies plan + saves outputs + generates Ansible host map), Destroy (manual with state cleanup).
- **02-ansible-configure.yml**: Polls SSH/WinRM connectivity, runs `site.yml` with per-OS routing, verifies web servers, generates deployment summary. Triggered by `workflow_run` on Terraform completion or manually.
- **03-full-cicd.yml**: Chains Terraform → Ansible as reusable workflows with `secrets: inherit`.
- **Secrets required**: `AWS_IAM_ROLE_ARN`, `SSH_PUBLIC_KEY`, `SSH_PRIVATE_KEY`.

### Scripts (`scripts/`)

| Script | Purpose |
|--------|---------|
| `01.generate-ssh-keys.sh` | Creates RSA 4096 key pair, uploads to GitHub Secrets via `gh` CLI |
| `02.setup-aws-oidc.sh` | Creates OIDC provider + IAM role for GitHub Actions (repo: mrbalraj007/aws-oidc-terraform-ansible-cicd) |
| `03.bootstrap.sh` | Creates S3 bucket with versioning + encryption + public access block |
| `configure-winrm.ps1` | PowerShell script that configures WinRM HTTPS listener, firewall rules |
| `generate-ansible-host-map.py` | Reads Terraform JSON output, writes `group_vars/generated_host_map.yml` with IP→username mapping |
| `outputs-to-summary.py` | Formats Terraform outputs for GitHub Actions step summary |
| `inventory-host-details.py` | Formats Ansible inventory JSON for step summary display |
| `inventory-summary-table.py` | Creates markdown table of hosts from Ansible inventory |
| `check-inventory-group.py` | Checks if a named group has hosts in the inventory JSON |
| `get-windows-passwords.py` | Retrieves Windows admin passwords from EC2 using the deployer private key |
| `parse-servers-to-summary.py` | Parses `terraform.tfvars` servers into a markdown table |