# Enterprise Multi-OS Provisioning & Configuration

**Terraform + Ansible + GitHub Actions** — Provision **Windows, Ubuntu, Amazon Linux, and Red Hat** EC2 instances from a single `terraform.tfvars` inventory file, then automatically configure each OS with the correct Ansible playbook.

---

## Architecture

```
terraform.tfvars (server definitions)
       │
       ▼
┌──────────────────────────────────────────┐
│  Terraform (modular)                     │
│                                          │
│  modules/ec2_instance/                   │
│    ├── Security Group (per OS group)     │
│    ├── EC2 Instance(s) + tags            │
│    │     ├── tag:OS_Type=amazon_linux    │
│    │     ├── tag:OS_Type=ubuntu          │
│    │     ├── tag:OS_Type=redhat          │
│    │     └── tag:OS_Type=windows         │
│    └── EBS + Spot + IMDSv2               │
└────────────────────────┬─────────────────┘
                         │ on success
                         ▼
┌──────────────────────────────────────────┐
│  Ansible (multi-OS)                      │
│                                          │
│  Dynamic Inventory (EC2 tags)            │
│    tag_OS_Type_amazon_linux  ──► os_amazon_linux.yml  (dnf, nginx)      │
│    tag_OS_Type_ubuntu        ──► os_ubuntu.yml        (apt, nginx)      │
│    tag_OS_Type_redhat        ──► os_redhat.yml        (dnf, nginx)      │
│    tag_OS_Type_windows       ──► os_windows.yml       (WinRM, IIS)      │
└──────────────────────────────────────────┘
```

---

## Quick Start

### 1. Generate SSH Keys
```bash
./scripts/01.generate-ssh-keys.sh
```

### 2. Setup AWS OIDC
```bash
./scripts/02.setup-aws-oidc.sh
```

### 3. Bootstrap Terraform State Bucket
```bash
./scripts/03.bootstrap.sh
```

### 4. Configure Server Inventory

Edit `terraform/terraform.tfvars`:

```hcl
servers = [
  {
    name          = "web-server"
    os_type       = "amazon_linux"    # amazon_linux | ubuntu | redhat | windows
    instance_type = "t3.medium"
    count         = 2
    volume_size   = 30
    role          = "web"
  },
  {
    name          = "windows-app"
    os_type       = "windows"
    instance_type = "t3.large"
    count         = 1
    volume_size   = 100
    role          = "app"
  },
]
```

### 5. Add GitHub Secrets

| Secret | Description |
|--------|-------------|
| `AWS_IAM_ROLE_ARN` | IAM Role ARN for OIDC authentication |
| `SSH_PUBLIC_KEY` | Public key injected into EC2 via Terraform |
| `SSH_PRIVATE_KEY` | Private key used by Ansible to SSH into EC2 |

### 6. Push to `main`

The CI/CD pipeline runs automatically:
1. **Terraform** provisions instances with OS-appropriate security groups and tags
2. **Ansible** discovers instances via dynamic inventory and runs the correct OS playbook

---

## Project Structure

```
.
├── terraform/
│   ├── main.tf                     # Root module — iterates over var.servers
│   ├── variables.tf                # Root variables (including servers list)
│   ├── outputs.tf                  # Aggregated outputs per server group
│   ├── amis.tf                     # Centralized AMI map per OS per region
│   ├── terraform.tfvars            # ← YOUR SERVER INVENTORY
│   ├── terraform.tfvars.example    # Documentation with all OS types
│   └── modules/
│       └── ec2_instance/           # Reusable EC2 module
│           ├── main.tf             # EC2 + SG + EIP + Key Pair
│           ├── variables.tf        # Module inputs
│           ├── outputs.tf          # Module outputs
│           └── README.md           # Module docs
├── ansible/
│   ├── ansible.cfg                 # Ansible configuration
│   ├── aws_ec2.yml                 # AWS EC2 dynamic inventory plugin
│   ├── requirements.yml            # Ansible collection dependencies
│   ├── group_vars/
│   │   ├── all.yml                 # Global variables
│   │   ├── tag_OS_Type_amazon_linux.yml  # Amazon Linux connection vars
│   │   ├── tag_OS_Type_ubuntu.yml        # Ubuntu connection vars
│   │   ├── tag_OS_Type_redhat.yml        # RedHat connection vars
│   │   └── tag_OS_Type_windows.yml       # Windows connection vars (WinRM)
│   ├── playbooks/
│   │   ├── site.yml                # Master orchestrator
│   │   ├── os_amazon_linux.yml     # Amazon Linux 2023 (dnf/nginx)
│   │   ├── os_ubuntu.yml           # Ubuntu 24.04 (apt/nginx)
│   │   ├── os_redhat.yml           # RHEL 9 (dnf/selinux/nginx)
│   │   └── os_windows.yml          # Windows Server 2022 (WinRM/IIS)
│   └── roles/
│       ├── common/                 # OS-agnostic Linux common role
│       ├── windows_common/         # Windows common role (timezone, registry)
│       └── webserver/              # Nginx web server role
├── scripts/
│   ├── 01.generate-ssh-keys.sh
│   ├── 02.setup-aws-oidc.sh
│   ├── 03.bootstrap.sh
│   └── 04.delete-aws-oidc.sh
└── .github/workflows/
    ├── 01-terraform-provision.yml  # Terraform plan/apply/destroy
    ├── 02-ansible-configure.yml    # Multi-OS Ansible runner
    └── 03-full-cicd.yml           # Combined pipeline
```

---

## Supported OS Types

| OS Type | AMI Source | SSH/RDP User | Connection | Package Mgr | Web Server |
|---------|-----------|--------------|------------|-------------|------------|
| `amazon_linux` | Amazon Linux 2023 | `ec2-user` | SSH | dnf | nginx |
| `ubuntu` | Ubuntu 24.04 LTS | `ubuntu` | SSH | apt | nginx |
| `redhat` | RHEL 9 | `ec2-user` | SSH | dnf | nginx |
| `windows` | Windows Server 2022 | `Administrator` | WinRM (5986) | chocolatey | IIS |

---

## Enterprise Features

- **Modular Terraform**: Reusable `ec2_instance` module with `for_each` iteration over server definitions
- **Multi-OS Ansible**: OS-specific playbooks with correct package managers, users, and web servers
- **Security Hardening**: IMDSv2 enforcement, EBS encryption, OS-appropriate security groups
- **Spot Instances**: Configurable spot pricing per instance group
- **Windows Support**: WinRM over HTTPS, Elastic IPs for stable WinRM endpoint, IIS deployment
- **Comprehensive Tagging**: `OS_Type`, `Role`, `Environment` tags for inventory grouping
- **Dynamic Inventory**: Ansible auto-discovers instances and groups by OS type
- **CI/CD Pipelines**: GitHub Actions with OIDC authentication, plan/apply/destroy lifecycle

---

## CI/CD Pipeline

### Manual Trigger
```bash
# Trigger full pipeline (provision + configure)
gh workflow run "3 - Full CI/CD Pipeline (Provision + Configure)" \
  --ref main \
  -f environment=dev

# Destroy infrastructure
gh workflow run "1 - Terraform Provision Infrastructure" \
  --ref main \
  -f action=destroy
```

### Viewing Inventory
After a deployment, view the auto-discovered inventory:
```bash
cd ansible
ansible-inventory -i aws_ec2.yml --graph
ansible-inventory -i aws_ec2.yml --list | python3 -m json.tool
```


```sh
 All code is validated: Terraform passes validate and fmt -check — all Ansible YAML parses clean.

  What was built:

  1. Custom Terraform Module (terraform/modules/ec2_instance/)
  - Reusable ec2_instance module with main.tf, variables.tf, outputs.tf, README.md
  - OS-appropriate security groups (SSH for Linux, RDP+WinRM for Windows)
  - Spot/on-demand, EBS encryption, IMDSv2, EBS optimization
  - Elastic IPs for Windows (required for WinRM trust)

  2. Root Terraform Refactor
  - amis.tf — Central AMI data sources for all 4 OS types
  - main.tf — Iterates var.servers via for_each, calling the module per server group
  - variables.tf — New servers variable as a list of objects with per-entry OS type
  - outputs.tf — Per-group, aggregated, and OS-specific outputs + admin user map

  3. Multi-OS Ansible Playbooks

  ┌─────────────────────┬─────────────────────┬─────────────┬───────────────┬─────────────────┐
  │      Playbook       │         OS          │ Package Mgr │   SSH User    │   Web Server    │
  ├─────────────────────┼─────────────────────┼─────────────┼───────────────┼─────────────────┤
  │ os_amazon_linux.yml │ Amazon Linux 2023   │ dnf         │ ec2-user      │ nginx           │
  ├─────────────────────┼─────────────────────┼─────────────┼───────────────┼─────────────────┤
  │ os_ubuntu.yml       │ Ubuntu 24.04        │ apt         │ ubuntu        │ nginx (UFW)     │
  ├─────────────────────┼─────────────────────┼─────────────┼───────────────┼─────────────────┤
  │ os_redhat.yml       │ RHEL 9              │ dnf         │ ec2-user      │ nginx (SELinux) │
  ├─────────────────────┼─────────────────────┼─────────────┼───────────────┼─────────────────┤
  │ os_windows.yml      │ Windows Server 2022 │ chocolatey  │ Administrator │ IIS (WinRM)     │
  └─────────────────────┴─────────────────────┴─────────────┴───────────────┴─────────────────┘

  4. Ansible OS Group Vars
  - tag_OS_Type_*.yml — Connection params (SSH user, WinRM, package manager, web root)
  - all.yml — Global vars shared across OS types

  5. Updated Inventory — aws_ec2.yml now groups by tag:OS_Type, tag:Role, tag:Environment

  6. CI/CD Pipelines — Multi-OS aware:
  - Tests SSH for Linux groups, WinRM for Windows groups
  - OS-specific deployment summaries in job output
  - Generates admin user map from Terraform outputs

  How to use:

  Edit terraform/terraform.tfvars — add your servers as a list:

  servers = [
    { name = "web",   os_type = "amazon_linux", instance_type = "t3.medium", count = 2, role = "web" },
    { name = "app",   os_type = "ubuntu",       instance_type = "t3.medium", count = 1, role = "app" },
    { name = "win",   os_type = "windows",      instance_type = "t3.large",  count = 1, role = "app" },
  ]

  Push to main — Terraform provisions everything, Ansible auto-discovers OS types and runs the correct playbook for each.
```