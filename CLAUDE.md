# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Enterprise Multi-OS Provisioning & Configuration** — Provisions Windows, Ubuntu, Amazon Linux, and Red Hat EC2 instances from a single `terraform.tfvars` inventory file, then automatically configures each OS with the correct Ansible playbook. Includes CloudWatch monitoring (CPU/Memory/Disk alerts via SNS email). The full CI/CD pipeline runs on GitHub Actions with OIDC authentication.

## Key Architecture

```
terraform.tfvars (server list) → Terraform (EC2 + SG + tags + monitoring) → Ansible (dynamic inventory by OS tag → OS-specific playbook)
```

Three layers, each independently operable:

- **Terraform** (`terraform/`) — Root module iterates `var.servers` with `for_each`, calling `modules/ec2_instance/` per server group. AMI lookups centralized in `amis.tf`. CloudWatch monitoring resources (SNS, IAM role for CW Agent, metric alarms) live in the root module and are gated by `create_cw_alarms`. The EC2 module receives an IAM instance profile and injects CW Agent installation via user_data templates.
- **Ansible** (`ansible/`) — AWS EC2 dynamic inventory (`aws_ec2.yml`) discovers instances by tags. Playbooks are routed by OS type group (`tag_OS_Type_*`). Master orchestrator `playbooks/site.yml` delegates to OS-specific playbooks. OS-specific connection params in `group_vars/tag_OS_Type_*.yml`.
- **CI/CD** (`.github/workflows/`) — Four reusable workflows: plan-only (`00`), provision (`01`), configure (`02`), full pipeline (`03`). Secrets managed at repo level.

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
cd terraform && TF_VAR_ssh_public_key="$(gh secret view SSH_PUBLIC_KEY --repo OWNER/REPO)" terraform plan -var-file="terraform.tfvars"
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
# Step 1: Create IAM Role + OIDC provider for GitHub Actions
./scripts/01.setup-aws-oidc.sh

# Step 2: Create S3 bucket for Terraform remote state
./scripts/02.setup_s3-backend.sh

# Step 3: Tear down OIDC
./scripts/03.delete-aws-oidc.sh

# Step 4: Destroy S3 backend
./scripts/04.destroy-s3-backend.sh
```

### GitHub Actions (manual triggers)

```bash
# Full pipeline
gh workflow run "3 - Full CI/CD Pipeline (Provision + Configure)" --ref main -f environment=dev

# Terraform plan only
gh workflow run "0 - Terraform Plan" --ref main -f environment=dev

# Terraform destroy
gh workflow run "1 - Terraform Provision Infrastructure" --ref main -f action=destroy
```

## Important Design Details

### Terraform

- **Root module** (`terraform/main.tf`): Creates `aws_key_pair`, iterates `var.servers` with `for_each` calling the `ec2_instance` module. Also creates CloudWatch monitoring resources when `create_cw_alarms = true`.
- **Server definitions** (`terraform/terraform.tfvars`): List of objects with fields: `name`, `os_type`, `instance_type`, `count`, `volume_size`, `role`, `environment` (optional), `spot_price` (optional). `os_type` must be one of: `amazon_linux`, `ubuntu`, `redhat`, `windows`.
- **AMI lookups** (`terraform/amis.tf`): Uses `data.aws_ami` with `most_recent = true`. Sources: Amazon (Amazon Linux, Windows), Canonical (099720109477 for Ubuntu), Red Hat (309956199498 for RHEL).
- **Module** (`terraform/modules/ec2_instance/`): Creates per-group security groups, EC2 instances with IMDSv2 enforcement, EBS encryption, optional spot pricing. Accepts optional `iam_instance_profile` for CloudWatch Agent. OS admin users: `ec2-user` (Amazon Linux/RHEL), `ubuntu`, `Administrator` (Windows).
- **CloudWatch monitoring** (root `main.tf`): IAM role + instance profile with `CloudWatchAgentServerPolicy`, SNS topic + email subscription, metric alarms (CPU/Memory/Disk at 80% threshold, 2 evaluation periods). Alarm naming: `EC2 <group-name>-{CPU,Memory,Disk}-Alerts`.
- **CW Agent installation**: Linux instances get a bash user_data script; Windows instances get a PowerShell snippet appended to the WinRM bootstrap. Both install the unified CloudWatch Agent and configure `mem_used_percent`, `disk_used_percent`, and `swap_used_percent` collection.
- **State backend**: S3 bucket (created by `02.setup_s3-backend.sh`) in `us-east-1`. Bucket name includes date suffix.
- **Windows user_data**: `scripts/configure-winrm.ps1` passed as base64-encoded PowerShell for Windows instances only. If CW monitoring is enabled, the agent installer is appended.

### Ansible

- **Dynamic inventory** (`ansible/aws_ec2.yml`): Uses `amazon.aws.aws_ec2` plugin. Filters on `tag:Project=tf-ansible-demo` and `tag:ManagedBy=Terraform`. Creates groups from `tags.Role`, `tags.OS_Type`, `tags.Environment`, and `instance_type`.
- **Group vars**: OS-specific connection parameters in `ansible/group_vars/tag_OS_Type_*.yml`. `ansible/group_vars/all.yml` has global variables.
- **site.yml**: Routes to OS-specific plays by `tag_OS_Type_*`. Linux plays run `common` + `webserver` roles; Windows runs `windows_common` role.
- **Roles**: `common` (packages, timezone, MOTD — handles AL2023 curl-minimal conflict), `webserver` (nginx install/config/template for Linux), `windows_common` (Windows updates, timezone, execution policy, RDP, temp cleanup, IE ESC disable).
- **WinRM**: Windows uses self-signed cert + HTTPS (port 5986) with basic auth. `scripts/configure-winrm.ps1` runs at boot via user_data. Pipeline polls for WinRM readiness and retrieves admin passwords from EC2.
- **WinRM HTTP verification in CI**: Post-playbook web checks use `--limit` to skip Windows hosts (the `uri` module requires Python on the target).

### CI/CD Pipeline

- **00-terraform-plan.yml**: Plan-only workflow (fmt check + validate + `terraform plan`). Good for review before apply.
- **01-terraform-provision.yml**: Plan + Apply (with host map generation), or Destroy (with state cleanup). Manual `action` input: `plan`, `apply`, `destroy`.
- **02-ansible-configure.yml**: Polls SSH/WinRM connectivity, runs `site.yml`, verifies web servers (Linux only), generates summary. Triggered by `workflow_run` on Terraform completion or manually.
- **03-full-cicd.yml**: Chains Terraform → Ansible as reusable workflows with `secrets: inherit`.
- **Secrets required**: `AWS_IAM_ROLE_ARN`, `SSH_PUBLIC_KEY`, `SSH_PRIVATE_KEY`.

### Scripts (`scripts/`)

| Script | Purpose |
|--------|---------|
| `01.setup-aws-oidc.sh` | Creates OIDC provider + IAM role for GitHub Actions |
| `02.setup_s3-backend.sh` | Creates S3 bucket with versioning + encryption + public access block |
| `03.delete-aws-oidc.sh` | Tears down the OIDC provider and IAM role |
| `04.destroy-s3-backend.sh` | Destroys the S3 state backend bucket |
| `configure-winrm.ps1` | PowerShell script that configures WinRM HTTPS listener, firewall rules |
| `generate-ansible-host-map.py` | Reads Terraform JSON output, writes `group_vars/generated_host_map.yml` |
| `outputs-to-summary.py` | Formats Terraform outputs for GitHub Actions step summary |
| `inventory-host-details.py` | Formats Ansible inventory JSON for step summary display |
| `inventory-summary-table.py` | Creates markdown table of hosts from Ansible inventory |
| `check-inventory-group.py` | Checks if a named group has hosts in the inventory JSON |
| `get-windows-passwords.py` | Retrieves Windows admin passwords from EC2 via deployer private key |
| `parse-servers-to-summary.py` | Parses `terraform.tfvars` servers into a markdown table |
| `get-inventory-ips.py` | Extracts IPs for a specific OS type group from inventory JSON |
| `plan-resource-table.py` | Formats Terraform plan resource count into a summary table |

## Terraform Module Architecture

```
terraform/
├── main.tf              # Root: key pair, EC2 module calls, monitoring (SNS/IAM/alarms)
├── variables.tf          # Root variables + servers list object type
├── outputs.tf            # Aggregated outputs + monitoring outputs
├── amis.tf               # Centralized AMI data sources per OS
├── backend.tf            # S3 remote state config
├── terraform.tfvars      # Server inventory + monitoring toggle
├── modules/
│   └── ec2_instance/
│       ├── main.tf       # SG, EC2 instance, spot, IMDSv2, user_data (CW agent)
│       ├── variables.tf  # All module inputs
│       ├── outputs.tf    # Instance IDs, IPs, admin user, group name
│       └── templates/
│           ├── cw-agent-setup.sh    # CW Agent install (Linux bash)
│           └── cw-agent-setup.ps1   # CW Agent install (Windows PowerShell)
```

### How user_data is resolved

The module's `user_data_base64` follows this priority:
1. Windows with `winrm_password` → inject password into WinRM script
2. Windows with IAM profile → WinRM script + CW Agent appended
3. Linux with IAM profile → CW Agent setup only (no existing script)
4. No monitoring → `null`