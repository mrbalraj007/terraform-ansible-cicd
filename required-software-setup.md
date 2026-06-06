# Required Software & Setup Guide

## Project Overview

This project provisions **AWS EC2 instances** using Terraform and configures them using Ansible, all orchestrated through GitHub Actions CI/CD.

---

## 📦 What Resources Will Be Created

### Terraform Provisions (on AWS)

| Resource | Type | Details | Quantity |
|---|---|---|---|
| `aws_security_group.app_sg` | Security Group | SSH (port 22) + HTTP (port 80) inbound, all outbound | 1 |
| `aws_key_pair.deployer` | Key Pair | SSH public key injected for instance access | 1 |
| `aws_instance.web` | EC2 Instance | t3.micro, Amazon Linux 2, 20GB gp3 encrypted root volume | **2** (configurable via `web_instance_count`) |
| `aws_instance.app` | EC2 Instance | t3.micro, Amazon Linux 2, 20GB gp3 encrypted root volume | **1** (configurable via `app_instance_count`) |

**Tags on all instances:** `Role=web|app`, `Environment=dev|staging|prod`, `Project=tf-ansible-demo`, `ManagedBy=Terraform`

### Ansible Configures (on EC2 instances)

| Role | Target Group | What It Installs / Configures |
|---|---|---|
| **common** | web + app | System updates, curl, wget, unzip, git, python3, UTC timezone, custom MOTD |
| **webserver** | `tag_Role_web` | **nginx** with custom `index.html` (shows hostname + environment) |
| **appserver** | `tag_Role_app` | **Java 11 (Amazon Corretto)**, `/opt/app` directory |

---

## ✅ Current Local Setup Status

| Software | Installed Version | Required Version | Status |
|---|---|---|---|
| **Terraform** | v1.15.3 | >= 1.5.0 | ✅ Installed (update to 1.15.5 available) |
| **AWS CLI** | v2.34.48 | Any v2 | ✅ Installed |
| **Python 3** | 3.10.12 | >= 3.9 | ✅ Installed |
| **pip3** | 22.0.2 | Any | ✅ Installed |
| **Git** | 2.34.1 | Any | ✅ Installed |
| **boto3** | 1.43.1 | Any | ✅ Installed |
| **Ansible** | ❌ Not installed | 9.5.1 | ❌ **Missing** |
| **Ansible Collections** | ❌ None found | amazon.aws, community.general, ansible.posix | ❌ **Missing** |
| **SSH Key** (`deployer_key`) | ❌ Not found | Ed25519 key pair | ❌ **Missing** |

---

## 🛠️ Installation Steps

### Step 1: Install Ansible

```bash
pip3 install ansible==9.5.1
```

Verify installation:

```bash
ansible --version
```

### Step 2: Install Ansible Collections

```bash
ansible-galaxy collection install amazon.aws:">=7.0.0"
ansible-galaxy collection install community.general:">=8.0.0"
ansible-galaxy collection install ansible.posix:">=1.5.0"
```

Or install all at once from the project's requirements file:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

Verify:

```bash
ansible-galaxy collection list | grep -E "amazon.aws|community.general|ansible.posix"
```

### Step 3: Generate SSH Key Pair

Generate a deployer SSH key for Ansible to connect to EC2 instances:

```bash
# Using the project script:
bash scripts/generate-ssh-keys.sh

# Or manually:
ssh-keygen -t ed25519 -f ~/.ssh/deployer_key -N ""
```

This creates two files:
- `~/.ssh/deployer_key` — **private key** (never commit this!)
- `~/.ssh/deployer_key.pub` — **public key**

### Step 4: (Optional) Update Terraform

```bash
# Download latest from: https://developer.hashicorp.com/terraform/install
# Or use tfenv:
# tfenv install 1.15.5 && tfenv use 1.15.5
```

---

## ☁️ Pre-Setup — AWS & GitHub Configuration

### GitHub Secrets Required

These secrets must be configured in your GitHub repository (**Settings → Secrets and variables → Actions**):

| Secret | Description | Source / Value |
|---|---|---|
| `AWS_IAM_ROLE_ARN` | IAM Role ARN for OIDC | Run `bash scripts/setup-aws-oidc.sh` |
| `SSH_PUBLIC_KEY` | Public key for EC2 key pair | Content of `~/.ssh/deployer_key.pub` |
| `SSH_PRIVATE_KEY` | Private key for Ansible SSH | Content of `~/.ssh/deployer_key` |

**Alternative (for `cicd.yml` workflow using static credentials):**

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM user secret key |

### S3 Backend Setup

The Terraform state is stored in S3. Create a bucket and update `terraform/main.tf`:

```hcl
backend "s3" {
  bucket = "your-unique-bucket-name"  # ← Change this
  key    = "terraform-ansible/terraform.tfstate"
  region = "us-east-1"
}
```

### Set AWS Region & SSH CIDR

Edit `terraform/terraform.tfvars` to match your environment:

```hcl
aws_region        = "us-east-1"         # Change if needed
allowed_ssh_cidr  = ["YOUR_IP/32"]      # Restrict SSH to your IP
ssh_public_key    = ""                  # Leave empty; injected from SSH_PUBLIC_KEY secret
```

---

## 🚀 Running the Pipeline

### Option A: GitHub Actions (automated)

Push to `main` branch and the CI/CD pipeline runs automatically via the configured workflows.

**Key flow (fully automated):**
1. **`01.generate-ssh-keys.sh`** generates keys locally and uploads to GitHub Secrets (`SSH_PUBLIC_KEY`, `SSH_PRIVATE_KEY`)
2. **`01-terraform-provision.yml`** reads `SSH_PUBLIC_KEY` from repo secrets → sets `TF_VAR_ssh_public_key` → Terraform creates AWS key pair
3. **`02-ansible-configure.yml`** reads `SSH_PRIVATE_KEY` from repo secrets → writes to `~/.ssh/deployer_key` → Ansible connects to EC2 instances

### Option B: Local Testing

```bash
# 1. Export the SSH key from the repo secret (one-time)
gh secret list --repo "$(gh repo view --json nameWithOwner -q '.nameWithOwner')"
gh secret view SSH_PUBLIC_KEY --repo "$(gh repo view --json nameWithOwner -q '.nameWithOwner')" > ~/.ssh/deployer_key.pub
gh secret view SSH_PRIVATE_KEY --repo "$(gh repo view --json nameWithOwner -q '.nameWithOwner')" > ~/.ssh/deployer_key
chmod 600 ~/.ssh/deployer_key

# 2. Initialize Terraform
cd terraform
terraform init

# 3. Plan
terraform plan -var="ssh_public_key=$(cat ~/.ssh/deployer_key.pub)"

# 4. Apply
terraform apply -auto-approve -var="ssh_public_key=$(cat ~/.ssh/deployer_key.pub)"

# 5. Run Ansible
cd ../ansible
ansible-inventory -i aws_ec2.yml --graph
ansible-playbook -i aws_ec2.yml playbooks/site.yml --private-key ~/.ssh/deployer_key
```

---

## 🧹 Clean Up

To destroy all created resources:

```bash
cd terraform
terraform destroy -auto-approve -var="ssh_public_key=$(cat ~/.ssh/deployer_key.pub)"
```

Or trigger the destroy workflow manually via GitHub Actions (`workflow_dispatch` with action: `destroy`).