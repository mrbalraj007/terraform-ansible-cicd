# Enterprise Multi-OS Provisioning & Configuration

**Infrastructure as Code — Terraform + Ansible + GitHub Actions**

A production-grade infrastructure automation system that provisions Windows Server 2022, Ubuntu 24.04, Amazon Linux 2023, and Red Hat Enterprise Linux 9 EC2 instances from a single inventory file, then configures each OS with the correct package manager, web server, and security baseline — all through a GitOps CI/CD pipeline secured with AWS OIDC.

---

## Table of Contents

1. [Why This Project Exists](#-why-this-project-exists)
2. [Architecture Overview](#-architecture-overview)
3. [Advantages Over Alternatives](#-advantages-over-alternatives)
4. [Prerequisites](#-prerequisites)
5. [Folder Structure Explained](#-folder-structure-explained)
6. [How It Works — Layer by Layer](#-how-it-works--layer-by-layer)
7. [Supported Operating Systems](#-supported-operating-systems)
8. [Setup Guide](#-setup-guide)
9. [CI/CD Pipeline](#-cicd-pipeline)
10. [Local Development & Testing](#-local-development--testing)
11. [Enterprise Features](#-enterprise-features)
12. [Troubleshooting](#-troubleshooting)
13. [Cleanup](#-cleanup)

---

## Why This Project Exists

Managing infrastructure across multiple operating systems in the cloud is a common challenge for any organization. The traditional approach — manually launching instances, logging in via SSH, and configuring each server individually — does not scale and introduces configuration drift.

This project was built to solve three specific problems:

1. **Multi-OS complexity.** Most provisioning tools assume a single OS. When you need Windows for .NET applications, Amazon Linux for cost-optimized workloads, Ubuntu for container hosts, and RHEL for compliance-bound services, you end up maintaining separate toolchains. This project unifies them under one declarative inventory.

2. **Terraform-to-Ansible handoff is a gap everyone hits.** Terraform is great at creating cloud resources, but it is not a configuration management tool. Ansible is great at configuring servers, but it does not provision infrastructure. Bridging them means extracting Terraform outputs, mapping them to Ansible inventories, and managing SSH keys across both tools. This project automates that handoff end-to-end so you never manually copy an IP address or write a static inventory file.

3. **CI/CD for infrastructure, not just application code.** Infrastructure changes should go through the same review, planning, and audit trail as application code. With GitHub Actions and OIDC-based AWS authentication, every change to your server inventory or playbook goes through plan → review → apply, with CloudWatch monitoring attached automatically.

### When To Use This Project

- You manage EC2 instances running **two or more operating systems** and want a single source of truth for both provisioning and configuration.
- Your team needs **guardrails**: Terraform plan in every PR, approvals before apply, and an immutable audit trail of who changed what.
- You want **monitoring attached at provisioning time**, not bolted on later by a separate team or tool.
- You are adopting **GitOps for infrastructure** and need a reference architecture that works with GitHub Actions OIDC.
- You run **Windows and Linux side-by-side** and are tired of maintaining separate pipelines for WinRM vs SSH, chocolatey vs dnf, IIS vs nginx.

### When Not To Use This Project

- You only run one OS type and one or two instances — a single Terraform file with inline Ansible provisioners is simpler.
- You need Kubernetes or container orchestration — this is a virtual-machine provisioning pipeline, not a container platform.
- You need real-time configuration enforcement with a daemon (like Chef or Puppet) — Ansible is push-based, not agent-based.
- You are already on AWS Systems Manager (SSM) for all configuration — this project uses SSH/WinRM, not SSM RunCommand.

---

## Architecture Overview

The system has three independently operable layers connected by automated handoffs:

```
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                           GITHUB ACTIONS CI/CD                              │
 │                                                                             │
 │   PR (opened)            Push to main           Manual Trigger              │
 │       │                       │                       │                     │
 │       ▼                       ▼                       ▼                     │
 │  Terraform Plan         Full Pipeline            Terraform Destroy          │
 │  (00-plan.yml)     ┌──────────────────┐          (01-provision.yml)         │
 │                    │ 01-provision     │                                      │
 │                    │ (plan + apply)   │                                      │
 │                    │        │         │                                      │
 │                    │ 02-configure     │                                      │
 │                    │ (discover +      │                                      │
 │                    │  configure)      │                                      │
 │                    └──────────────────┘                                      │
 └───────────────────────────┬─────────────────────────────────────────────────┘
                             │
                             ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                         TERRAFORM (Provisioning Layer)                      │
 │                                                                             │
 │  terraform.tfvars ──────► Root Module (for_each) ──────► ec2_instance Module│
 │  (server list)                                                              │
 │  ┌──────────────┐        ┌──────────────────┐         ┌──────────────────┐  │
 │  │ web-server    │        │ ami lookup (amis)│         │ Security Group   │  │
 │  │ amazon_linux  │        │ TLS key gen      │──────► │ EC2 Instances    │  │
 │  │ count: 1      │──────► │ Key Pair upload  │         │ IMDSv2 enforced  │  │
 │  ├──────────────┤         │ IAM Role (CW)    │         │ EBS encrypted    │  │
 │  │ app-server    │        │ SNS Topic        │         │ Spot optional    │  │
 │  │ ubuntu        │        │ Metric Alarms    │         │ Tagged: OS_Type  │  │
 │  │ count: 1      │        └──────────────────┘         │ Tagged: Role     │  │
 │  ├──────────────┤                                        │ Tagged: Env    │  │
 │  │ win-server    │                                       └────────┬───────┘  │
 │  │ windows       │                                                 │          │
 │  │ count: 1      │                                                 │          │
 │  └──────────────┘                                         tags on instances   │
 └─────────────────────────────────────────────────────────────────────┬───────┘
                                                                       │
                                                                       ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                          ANSIBLE (Configuration Layer)                      │
 │                                                                             │
 │  aws_ec2.yml (dynamic inventory)                                            │
 │       │                                                                     │
 │       ▼                                                                     │
 │  Groups by tag:OS_Type, tag:Role, tag:Environment                           │
 │       │                                                                     │
 │       ▼                                                                     │
 │  ┌─────────────────────────────────────────────────────────────────────┐    │
 │  │  site.yml (master orchestrator)                                    │    │
 │  │     ├── tag_OS_Type_amazon_linux ──► common role + webserver role  │    │
 │  │     ├── tag_OS_Type_ubuntu       ──► common role + webserver role  │    │
 │  │     ├── tag_OS_Type_redhat       ──► common role + webserver role  │    │
 │  │     └── tag_OS_Type_windows      ──► windows_common role           │    │
 │  └─────────────────────────────────────────────────────────────────────┘    │
 │       │                                                                     │
 │       ▼                                                                     │
 │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐                    │
 │  │ Amazon   │  │ Ubuntu   │  │ RHEL     │  │ Windows  │                    │
 │  │ Linux    │  │ 24.04    │  │ 9        │  │ Server   │                    │
 │  │          │  │          │  │          │  │ 2022     │                    │
 │  │ dnf      │  │ apt      │  │ dnf      │  │ WinRM    │                    │
 │  │ nginx    │  │ nginx    │  │ SELinux  │  │ IIS      │                    │
 │  │ motd     │  │ UFW      │  │ nginx    │  │ choco    │                    │
 │  └──────────┘  └──────────┘  └──────────┘  └──────────┘                    │
 │                                                                             │
 └─────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                      CLOUDWATCH MONITORING (Observability)                  │
 │                                                                             │
 │  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                   │
 │  │ CPU Alarms   │    │ Memory Alarms│    │ Disk Alarms  │                   │
 │  │ (>80% avg)   │    │ (>80% avg)   │    │ (>80% avg)   │                   │
 │  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘                   │
 │         └──────────────────┼────────────────────┘                           │
 │                            ▼                                                │
 │                   ┌────────────────┐                                        │
 │                   │  SNS Topic     │                                        │
 │                   │  (Email)       │                                        │
 │                   └────────────────┘                                        │
 └─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow (End to End)

1. You define server groups in `terraform/terraform.tfvars` — each entry specifies a name, OS type, instance size, count, disk size, and role.
2. A **Terraform root module** iterates the list with `for_each`, calling the `ec2_instance` module once per server group. Each module creates a dedicated security group (SSH for Linux, WinRM+RDP for Windows) and the requested number of EC2 instances with IMDSv2 enforcement, EBS encryption, optional spot pricing, and CloudWatch Agent IAM profile.
3. Every instance is tagged with `OS_Type`, `Role`, `Environment`, `ManagedBy`, and `Project` — these tags are the bridge to Ansible.
4. Ansible uses the **AWS EC2 dynamic inventory plugin** (`aws_ec2.yml`) to discover all instances by tag. It groups them by `tag_OS_Type_*`, `tag_Role_*`, and `tag_Environment_*`.
5. The master playbook `site.yml` routes each OS group to its playbook, which applies the `common` role (updates, timezone, packages, MOTD) and the `webserver` role (nginx or IIS).
6. If CloudWatch monitoring is enabled, the IAM instance profile lets the CloudWatch Agent send memory, disk, and swap metrics. Three alarms per instance (CPU, memory, disk at 80% threshold) notify an SNS email subscription.

---

## Advantages Over Alternatives

| Concern | This Project | Terraform-only | Ansible-only | Manual |
|---|---|---|---|---|
| **Multi-OS support** | One inventory, four OS types | Multi-module, no OS config | Needs separate inventory per OS | Each OS managed separately |
| **Windows + Linux** | Unified pipeline | Requires separate config | Different auth methods manually | Completely separate processes |
| **State management** | S3 backend with encryption | ✓ | ✗ | ✗ |
| **CI/CD & approval gates** | PR plan + apply workflow | Requires external CI setup | Requires external CI setup | ✗ |
| **SSH/WinRM key mgmt** | Auto-generated, uploaded to S3 | Manual key management | Manual key management | Manual key management |
| **Monitoring setup** | Auto-attached via IAM + CW Agent at provision time | Requires separate Terraform | Requires separate setup | Manual setup per instance |
| **Dynamic inventory** | Auto-discovers by EC2 tags | ✗ | Needs ec2.py or manual | Static spreadsheet |
| **Security defaults** | IMDSv2, EBS encryption, spot, OS-specific security groups | Must configure each | ✗ | Easy to miss |
| **Audit trail** | Git history + GitHub Actions logs | ✗ | ✗ | ✗ |
| **Idempotency** | Both Terraform and Ansible are idempotent | ✓ Partial (state-dependent) | ✓ | ✗ |

### Why Terraform + Ansible Instead of

- **Terraform + user_data scripts.** User data scripts are fragile, hard to debug, and not idempotent. Ansible retries on failure, reports what changed, and you can re-run it without destroying instances.
- **Packer + Terraform.** Packer builds golden images. If you need to manage 4 OS images with different package versions, security patches, and application configurations, you are maintaining 4+ image pipelines. With Terraform + Ansible, you use stock AMIs and configure at boot — fewer images to manage.
- **Ansible-only.** Ansible does not create EC2 instances, security groups, key pairs, or SNS topics. You would need another tool to create those, or pre-provision them manually.
- **CDK / Pulumi.** While viable, they require programming language proficiency across the team. HCL (Terraform) + YAML (Ansible) has a lower barrier for operations teams.

---

## Prerequisites

### Required Software

Install these tools **before** setting up the project. Versions listed are the minimum tested versions; newer versions should work unless otherwise noted.

| Software | Minimum Version | Purpose | Installation Command |
|---|---|---|---|
| **Terraform** | >= 1.5.0 | Define and provision AWS infrastructure declaratively | [terraform.io/downloads](https://www.terraform.io/downloads) or `tfenv install 1.5.0` |
| **Ansible** | >= 9.0.0 (core >= 2.16) | Configure EC2 instances after provisioning | `pip3 install ansible` |
| **AWS CLI v2** | >= 2.0.0 | Authenticate with AWS for S3 operations and OIDC setup | `pip3 install awscli` or package manager |
| **Python 3** | >= 3.9 | Run automation scripts, helper utilities | `apt install python3` or `brew install python@3.11` |
| **pip3** | >= 21.0 | Install Ansible and Python dependencies | `apt install python3-pip` or `python3 -m ensurepip` |
| **Git** | >= 2.30.0 | Version control, GitHub Actions triggers | `apt install git` or `brew install git` |
| **boto3** | >= 1.26.0 | AWS SDK for Python (Ansible EC2 inventory, helper scripts) | `pip3 install boto3` |
| **OpenSSH** | >= 8.0 | Generate SSH keys, connect to Linux instances | Included in all modern OS, `apt install openssh-client` |
| **GitHub CLI (`gh`)** | >= 2.0.0 | Interact with GitHub from the command line | [cli.github.com](https://cli.github.com/) or `apt install gh` |
| **TLS/SSL tools** | (system) | Generate TLS key pair, decrypt Windows passwords | `apt install openssl` (usually pre-installed) |

### Required Ansible Collections

Installed via `ansible-galaxy collection install -r ansible/requirements.yml`:

| Collection | Version | Purpose |
|---|---|---|
| `amazon.aws` | >= 7.0.0 | AWS EC2 dynamic inventory plugin, AWS modules |
| `community.general` | >= 8.0.0 | General-purpose modules (package management, etc.) |
| `community.windows` | >= 2.0.0 | Windows-specific Ansible modules |
| `ansible.posix` | >= 1.5.0 | POSIX system modules (mount, selinux, autorun) |
| `ansible.windows` | >= 2.0.0 | Windows connection and WinRM modules |

### Required Python Packages

| Package | Purpose |
|---|---|
| `boto3` | AWS SDK — required by Ansible AWS EC2 inventory plugin and helper scripts |
| `botocore` | Core AWS SDK — dependency of boto3 |

### Required GitHub Repository Secrets

| Secret | Description | Source |
|---|---|---|
| `AWS_IAM_ROLE_ARN` | IAM Role ARN for OIDC-based GitHub Actions → AWS authentication | Created by `scripts/01.setup-aws-oidc.sh` |
| `SSH_PUBLIC_KEY` | Public SSH key injected into EC2 instances via Terraform | Run `cat ~/.ssh/deployer_key.pub` |
| `SSH_PRIVATE_KEY` | Private SSH key used by Ansible to connect to EC2 instances | Run `cat ~/.ssh/deployer_key` |

### Required AWS Resources

| Resource | Created By | Purpose |
|---|---|---|
| **OIDC Identity Provider** | `scripts/01.setup-aws-oidc.sh` | Allows GitHub Actions to assume an IAM role without long-lived keys |
| **IAM Role** | `scripts/01.setup-aws-oidc.sh` | Grants GitHub Actions permissions to create AWS resources |
| **S3 Bucket** | `scripts/02.setup_s3-backend.sh` | Stores Terraform state files with encryption and versioning |
| **EC2 Key Pair** | Created by Terraform at apply time | SSH access to Linux instances |

### Local Environment Variables (Optional)

These are set automatically by the setup scripts or GitHub Actions but should be noted:

| Variable | Where Set | Purpose |
|---|---|---|
| `TF_VAR_ssh_public_key` | GitHub Actions | Passes SSH public key to Terraform without hardcoding in tfvars |
| `TF_VAR_winrm_password` | GitHub Actions + setup script | WinRM password for Windows instances |
| `TF_VAR_tf_state_bucket` | GitHub Actions | S3 bucket name for state file |
| `AWS_REGION` | GitHub Actions | AWS region for all operations |

---

## Folder Structure Explained

```
├── .github/
│   ├── workflows/                    # CI/CD pipeline definitions (GitHub Actions)
│   │   ├── 00-terraform-plan.yml     # Plan-only — runs on every PR to main
│   │   ├── 01-terraform-provision.yml # Create or destroy infrastructure
│   │   ├── 02-ansible-configure.yml  # Discover and configure EC2 instances
│   │   └── 03-full-cicd.yml          # Orchestrates 01 + 02 in sequence
│   └── pull_request_template.md      # PR template with Terraform plan checklist
│
├── terraform/                        # Infrastructure-as-Code (HashiCorp Terraform)
│   ├── main.tf                       # Root module: key pair, module calls, CloudWatch monitoring
│   ├── variables.tf                  # All input variables including the servers list object
│   ├── outputs.tf                    # Per-group, aggregated, and OS-specific outputs
│   ├── amis.tf                       # AMI data sources for all 4 OS types per region
│   ├── backend.tf                    # S3 remote state configuration
│   ├── terraform.tfvars              # YOUR SERVER INVENTORY — edit this file
│   ├── terraform.tfvars.example      # Example inventory with all OS types
│   ├── .terraform.lock.hcl           # Provider version lock file
│   └── modules/
│       └── ec2_instance/             # Reusable EC2 instance module
│           ├── main.tf               # SG + EC2 + IMDSv2 + EBS + spot + user_data logic
│           ├── variables.tf          # 18 module input variables
│           ├── outputs.tf            # Instance IDs, IPs, admin user, tags
│           ├── README.md             # Module documentation
│           └── templates/
│               ├── cw-agent-setup.sh     # CloudWatch Agent install (Linux bash)
│               └── cw-agent-setup.ps1    # CloudWatch Agent install (Windows PowerShell)
│
├── ansible/                          # Configuration Management (Ansible)
│   ├── ansible.cfg                   # Global Ansible configuration (inventory, SSH, WinRM)
│   ├── aws_ec2.yml                   # AWS EC2 dynamic inventory plugin config
│   ├── requirements.yml              # Ansible collection dependencies
│   ├── group_vars/
│   │   ├── all.yml                   # Global variables shared across all OS types
│   │   ├── tag_OS_Type_amazon_linux.yml    # Connection params: ec2-user, dnf, nginx
│   │   ├── tag_OS_Type_ubuntu.yml          # Connection params: ubuntu, apt, nginx
│   │   ├── tag_OS_Type_redhat.yml          # Connection params: ec2-user, dnf, nginx
│   │   └── tag_OS_Type_windows.yml         # Connection params: WinRM, ansible_admin, IIS
│   ├── host_vars/                    # Per-host variables (populated by CI/CD scripts)
│   │   └── .gitkeep
│   ├── playbooks/                    # Ansible playbooks — one per OS plus master
│   │   ├── site.yml                  # Master orchestrator — routes by tag_OS_Type_*
│   │   ├── os_amazon_linux.yml       # Amazon Linux 2023: dnf, nginx, MOTD
│   │   ├── os_ubuntu.yml             # Ubuntu 24.04: apt, UFW, nginx, MOTD
│   │   ├── os_redhat.yml             # RHEL 9: dnf, SELinux, nginx, MOTD
│   │   └── os_windows.yml            # Windows Server 2022: WinRM, chocolatey, IIS
│   └── roles/
│       ├── common/                   # Linux common role (OS-agnostic)
│       │   ├── tasks/main.yml        # Updates, packages, timezone, MOTD deployment
│       │   └── templates/motd.j2     # Message of the day template (hostname, IP, OS)
│       ├── webserver/                # Linux web server role
│       │   ├── tasks/main.yml        # Install nginx, deploy HTML, start service, verify port 80
│       │   ├── handlers/main.yml     # Restart Nginx handler
│       │   └── templates/index.html.j2  # Default index page (hostname, IP, environment)
│       └── windows_common/           # Windows common role
│           └── tasks/main.yml        # Updates, timezone, RDP, execution policy, IIS
│
├── scripts/                          # Automation and utility scripts
│   ├── 01.setup-aws-oidc.sh          # Create IAM OIDC provider + role for GitHub Actions
│   │                                     # Also sets GitHub Secrets: AWS_IAM_ROLE_ARN, TF_VAR_winrm_password
│   ├── 02.setup_s3-backend.sh        # Create S3 bucket with versioning + encryption + Object Lock
│   │                                     # Writes backend.tf with bucket name, sets TF_VAR_tf_state_bucket secret
│   ├── 03.delete-aws-oidc.sh         # Teardown: delete OIDC provider + IAM role
│   ├── 04.destroy-s3-backend.sh      # Teardown: empty and delete S3 state bucket
│   ├── configure-winrm.ps1           # PowerShell: create ansible_admin user, WinRM HTTPS, firewall
│   │                                     # Runs as user_data on Windows instances
│   ├── generate-ansible-host-map.py  # Read Terraform outputs → write group_vars/admin_host_map.yml
│   ├── outputs-to-summary.py         # Format Terraform outputs as GitHub Actions step summary
│   ├── inventory-host-details.py     # Display Ansible inventory groups + per-host details
│   ├── inventory-summary-table.py    # Build markdown table of hosts from inventory JSON
│   ├── check-inventory-group.py      # Exit 0 if Ansible group has hosts, exit 1 otherwise
│   ├── get-inventory-ips.py          # Extract IPs for specific OS type from inventory JSON
│   ├── get-windows-passwords.py      # Decrypt Windows admin passwords via EC2 + private key
│   ├── parse-servers-to-summary.py   # Parse terraform.tfvars into markdown resource table
│   └── plan-resource-table.py        # Parse Terraform plan JSON into markdown change summary
│
├── architecture-diagram.drawio       # Enterprise architecture diagram (draw.io)
├── CLAUDE.md                         # Claude AI assistant instructions for code generation
├── README.md                         # This file
├── required-software-setup.md        # Detailed installation guide for prerequisites
└── .gitignore                        # Git ignore rules (Terraform, keys, OS files, etc.)
```

### Why Each Folder Exists

**`.github/workflows/`** — This is the CI/CD engine. Without it, you would run Terraform and Ansible manually from your laptop, which means no audit trail, no automated approvals, and no repeatability. Each workflow file serves one lifecycle phase so you can run them independently. The 00-plan workflow runs on every PR to catch Terraform errors before merge. The 01 and 02 workflows separate provisioning from configuration so you can re-run Ansible without re-creating instances. The 03 workflow chains them together for the full pipeline.

**`terraform/`** — This is the provisioning layer. Terraform was chosen because it is the industry-standard tool for declaring cloud infrastructure, it maintains state so it knows what it created, and its plan output lets you review changes before applying. The root module is deliberately thin — it only orchestrates, delegates to the ec2_instance module, and adds optional monitoring. AMIs are centralized in `amis.tf` so adding a new OS region or version requires one change. The `for_each` loop over `var.servers` means adding a new server group is a one-line addition to `terraform.tfvars` — no new module calls or data sources needed.

**`terraform/modules/ec2_instance/`** — This module encapsulates everything needed to create a group of EC2 instances for any OS. It creates the security group (with OS-appropriate ports), the instances (with IMDSv2, EBS encryption, spot options), and resolves user_data based on OS and monitoring flags. It exports structured outputs so the root module can build alarm configurations and host maps. Keeping this as a module means you can version, test, and reuse it across environments or even across projects.

**`ansible/`** — This is the configuration layer. Ansible was chosen because it is agentless (no software to install on targets), idempotent (running it twice produces the same result), and uses a simple YAML syntax that operations teams can read without programming experience. The dynamic inventory (`aws_ec2.yml`) is key — it queries the AWS API for running instances tagged with this project, so there is zero manual inventory management. The `group_vars/` pattern means each OS type has its own connection parameters (SSH user, package manager, web server root) and the right values are automatically applied. The `site.yml` master playbook is the single entry point: it checks which OS groups exist in the inventory and runs the correct playbook for each.

**`ansible/roles/`** — Roles are the Ansible way to organize reusable, self-contained configuration units. The `common` role handles system-level configuration that applies to all Linux instances regardless of OS (package updates, timezone, MOTD). The `webserver` role handles nginx installation and configuration. Separating them means you can apply `common` to every instance but only apply `webserver` to instances that should serve HTTP traffic. The `windows_common` role is isolated because Windows configuration (registry, IIS, chocolatey) shares no code with Linux roles.

**`scripts/`** — These utility scripts handle tasks that do not fit neatly into Terraform or Ansible: bootstrapping AWS infrastructure (OIDC, S3), decoding EC2 passwords, formatting output for CI/CD, and converting data between layers. The bootstrap scripts (01-04) are run once per AWS account, not per deployment. The CI/CD helper scripts (generate-ansible-host-map.py, etc.) are called by GitHub Actions workflows to bridge the gap between Terraform outputs and Ansible inputs.

---

## How It Works — Layer by Layer

### Layer 1: Terraform — Infrastructure Provisioning

**File: `terraform/main.tf`**

The root module does four things:

1. **Creates an SSH/RDP key pair.** A TLS private key is generated locally (RSA 4096-bit), uploaded to AWS as a key pair, saved to disk as `scripts/<project>-<env>-deployer-key.pem`, and copied to S3 so the CI/CD pipeline can retrieve it. No manual key management needed.

2. **Provisions EC2 instance groups.** For each entry in `var.servers`, it calls the `ec2_instance` module. The unique key format `"<role>-<os_type>-<index>"` means you can have multiple groups with the same OS type and role (e.g., two Ubuntu web server groups) without resource conflicts.

3. **Attaches monitoring infrastructure.** If `create_cw_alarms = true`, the root module creates:
   - An IAM role with the `CloudWatchAgentServerPolicy` attached to an instance profile
   - An SNS topic with an email subscription for alarm notifications
   - Three metric alarms per instance (CPU, memory, disk) at 80% threshold with 2 evaluation periods
   - Disk alarms include extra dimensions (`mount_path = "/"`, `filesystem = "*"`) for accurate root volume monitoring

4. **Generates structured outputs.** The `terraform output -json` command returns a complete map of instance IDs, public/private IPs, admin usernames, and OS types — the Ansible layer reads this to configure itself.

**How AMI selection works:** The `amis.tf` file defines four `data.aws_ami` data sources, one per OS type, using `most_recent = true` to always get the latest available AMI. The filters are specific enough to avoid matching the wrong AMI family (e.g., Amazon Linux 2 vs 2023). A `locals` map then resolves the right AMI by `os_type` string. To add a new region, duplicate the data sources with the correct region filter.

**How the module call works in detail:**

```hcl
module "server_group" {
  source = "./modules/ec2_instance"
  for_each = {
    for idx, s in var.servers : "${s.role}-${s.os_type}-${idx}" => s
  }
  # 18 variables passed to the module
  instance_count = each.value.count
  os_type        = each.value.os_type
  # ...
}
```

The `for_each` expression converts the list of server objects into a map keyed by a unique string. Terraform requires unique keys for `for_each`, and since two servers could have the same name, the index ensures uniqueness. Each module invocation gets its own state entry, so Terraform can plan, apply, or destroy individual server groups independently.

### Layer 2: Ansible — Configuration Management

**File: `ansible/playbooks/site.yml`**

Ansible discovers EC2 instances through the AWS API using the `amazon.aws.aws_ec2` inventory plugin. The plugin queries for:
- `tag:Project=tf-ansible-demo` — scoped to this project
- `tag:ManagedBy=Terraform` — avoids picking up manually created instances

Instances are automatically grouped into:
- `tag_OS_Type_amazon_linux`, `tag_OS_Type_ubuntu`, `tag_OS_Type_redhat`, `tag_OS_Type_windows`
- `tag_Role_web`, `tag_Role_app`, `tag_Role_db`
- `tag_Environment_dev`, `tag_Environment_staging`, `tag_Environment_prod`
- `instance_type_t3_micro`, etc.

**Why the playbook structure matters:** The master `site.yml` uses four separate `play` blocks, each targeting one OS group. This is not the same as using a single play with conditional tasks. Separate plays give you OS-specific connection settings (SSH user, WinRM), OS-specific fact gathering, and OS-specific error handling. If the Windows play fails, the Linux plays still complete.

**How configuration is applied per playbook:**

| Playbook | OS | What It Configures |
|---|---|---|
| `os_amazon_linux.yml` | Amazon Linux 2023 | `dnf update`, common packages (wget, unzip, git, tree, htop), nginx from dnf, index.html with hostname/IP, port 80 verification |
| `os_ubuntu.yml` | Ubuntu 24.04 | `apt update && apt upgrade`, common packages + software-properties-common, UFW firewall (SSH + HTTP), nginx with www-data ownership, service verification |
| `os_redhat.yml` | RHEL 9 | Subscription Manager (conditional), EPEL repo, common packages, SELinux boolean for nginx network connect, nginx, port verification |
| `os_windows.yml` | Windows Server 2022 | WinRM service hardening, chocolatey install, common tools (git, curl, wget, vim, 7zip), legal notice banner (Windows MOTD equivalent), IIS Web-Server role, firewall rule for port 80, default IIS page with hostname/IP/OS/environment |

**The OS-agnostic common role** (`roles/common/`) uses `ansible_os_family` facts to detect the package manager (apt, dnf, yum) and acts accordingly. It handles the Amazon Linux 2023 `curl-minimal` conflict by passing `allowerasing` to dnf when `curl` is requested — a subtle gotcha that cost time to debug the first time.

**Windows connection flow:**
1. On first boot, Windows EC2 runs `configure-winrm.ps1` as user_data — this creates a local `ansible_admin` user, configures WinRM with a self-signed HTTPS certificate on port 5986, and opens firewall ports 5985 and 5986.
2. The CI/CD pipeline polls for WinRM readiness by checking the EC2 console output and instance status.
3. Ansible connects via WinRM with basic auth over HTTPS using the `ansible_admin` account and `winrm_password`.
4. The Windows playbook executes, installing chocolatey and IIS, and applying registry settings.

### Layer 3: CloudWatch Monitoring

When `create_cw_alarms = true`, every provisioned instance gets:

1. **CloudWatch Agent installed via user_data.** For Linux, a bash script detects the OS family and installs the RPM or DEB package. For Windows, the MSI is downloaded from S3 and installed silently. Both write a config file that collects `mem_used_percent`, `disk_used_percent`, and `swap_used_percent` at 60-second intervals.

2. **An IAM instance profile** with the `CloudWatchAgentServerPolicy` managed policy so the agent can publish metrics without hardcoded credentials.

3. **Three CloudWatch metric alarms** per instance:
   - CPU: `AWS/EC2` → `CPUUtilization`, average over 5 min, 2 evaluation periods, threshold 80%
   - Memory: `CWAgent` → `mem_used_percent`, same period/evaluation/threshold
   - Disk: `CWAgent` → `disk_used_percent`, with `mount_path = "/"` and `filesystem = "*"` dimensions

4. **SNS topic** with configurable email subscription. Alarms publish to SNS on state transitions to ALARM, OK, and INSUFFICIENT_DATA.

### Layer 4: CI/CD — GitHub Actions

**Four workflows, one purpose:**

- **00-terraform-plan.yml** — Your safety net. Runs on every pull request to `main` that touches `terraform/`. It does init → validate → fmt-check → plan and posts the result as a PR comment. If the plan changes more resources than expected, discuss it in the PR before merging.

- **01-terraform-provision.yml** — The provisioning engine. Called as a reusable workflow by the full pipeline, or triggered manually with `workflow_dispatch`. Supports three actions: `plan` (just plan and upload), `apply` (download plan and execute), `destroy` (tear everything down). This separation means you can review a plan in the morning and apply it in the afternoon without re-planning.

- **02-ansible-configure.yml** — The configuration engine. Called after Terraform apply completes. It does: installs Ansible and collections → downloads Terraform outputs (instance IPs, admin users) → polls for SSH/WinRM readiness → runs the dynamic inventory → runs the Ansible site.yml → verifies web servers respond on port 80 → generates a deployment summary. The readiness polling is progressive: it waits up to 10 minutes for SSH and up to 15 minutes for WinRM (Windows can be slow to finish bootstrapping).

- **03-full-cicd.yml** — The orchestrator. Triggered on push to `main` (when terraform/, ansible/, or scripts/ changes). It calls 01 then 02 sequentially with `secrets: inherit`. A `skip_ansible` input lets you do Terraform-only deployments when needed.

**OIDC authentication:** The workflows use `aws-actions/configure-aws-credentials` with `role-to-assume` instead of long-lived AWS access keys. The OIDC provider is created by `scripts/01.setup-aws-oidc.sh` and the trust policy restricts which GitHub repository and branch can assume the role.

---

## Supported Operating Systems

| OS Type | AMI Source | SSH/RDP User | Connection | Package Manager | Web Server | Firewall |
|---|---|---|---|---|---|---|
| `amazon_linux` | Amazon Linux 2023 | `ec2-user` | SSH (port 22) | dnf | nginx | N/A (security groups) |
| `ubuntu` | Ubuntu 24.04 LTS | `ubuntu` | SSH (port 22) | apt | nginx | UFW |
| `redhat` | RHEL 9 | `ec2-user` | SSH (port 22) | dnf | nginx | SELinux |
| `windows` | Windows Server 2022 | `Administrator` | WinRM (port 5986) | chocolatey | IIS | Windows Firewall |

### Adding a New OS Type

The architecture is designed for extensibility. To add a new OS type:

1. Add an AMI data source in `terraform/amis.tf`
2. Add an entry to the `admin_user` and `ingress_rules` locals in `terraform/modules/ec2_instance/main.tf`
3. Add an AMI entry to `local.ami_ids` in `terraform/amis.tf`
4. Create `ansible/group_vars/tag_OS_Type_newos.yml` with connection parameters
5. Create `ansible/playbooks/os_newos.yml` with OS-specific tasks
6. Add a play block in `ansible/playbooks/site.yml` targeting `tag_OS_Type_newos`
7. Add the OS type to the validation rule in `terraform/variables.tf`

---

## Setup Guide

### Step 1: Install Prerequisites

```bash
# Verify installed tools
terraform --version
aws --version
python3 --version
git --version

# Install Ansible
pip3 install ansible

# Install Ansible collections
cd ansible
ansible-galaxy collection install -r requirements.yml

# Verify collections
ansible-galaxy collection list | grep -E "amazon.aws|community.general|ansible.posix"
```

### Step 2: Generate SSH Keys

```bash
ssh-keygen -t ed25519 -f ~/.ssh/deployer_key -N ""
```

### Step 3: Setup AWS OIDC

```bash
# Requires: AWS CLI configured with admin credentials
./scripts/01.setup-aws-oidc.sh
```

This script creates:
- An OIDC identity provider for `token.actions.githubusercontent.com`
- An IAM role (`github-actions-oidc-role`) with EC2, S3, DynamoDB, IAM, and SNS permissions
- GitHub secrets `AWS_IAM_ROLE_ARN` and `TF_VAR_winrm_password`

### Step 4: Create S3 State Bucket

```bash
./scripts/02.setup_s3-backend.sh
```

This creates:
- An S3 bucket with versioning, encryption (AES-256), Object Lock (7-day governance), and public access blocks
- A `backend.tf` file pointing to the new bucket
- A GitHub secret with the bucket name

### Step 5: Configure Server Inventory

Edit `terraform/terraform.tfvars` to define your server groups:

```hcl
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
    instance_type = "t3.medium"
    count         = 1
    volume_size   = 50
    role          = "app"
  },
]
```

### Step 6: Add GitHub Secrets

| Secret | Value |
|---|---|
| `AWS_IAM_ROLE_ARN` | Created by Step 3 |
| `SSH_PUBLIC_KEY` | `cat ~/.ssh/deployer_key.pub` |
| `SSH_PRIVATE_KEY` | `cat ~/.ssh/deployer_key` |

### Step 7: Push to main

```bash
git add .
git commit -m "Configure server inventory"
git push origin main
```

The CI/CD pipeline (03-full-cicd.yml) runs automatically:
1. Terraform init → validate → fmt check → plan → apply
2. Ansible discovers instances → runs OS-specific playbooks
3. Web server verification (Linux via ansible uri, Windows via curl)

---

## CI/CD Pipeline

### Available Workflows

| Workflow | File | Trigger | What It Does |
|---|---|---|---|
| **0 - Terraform Plan** | `00-terraform-plan.yml` | PR to main (terraform/**) | Init, validate, fmt, plan, post comment |
| **1 - Terraform Provision** | `01-terraform-provision.yml` | workflow_call, workflow_dispatch | Plan (or apply/destroy) |
| **2 - Ansible Configure** | `02-ansible-configure.yml` | workflow_call, workflow_dispatch | Install Ansible, wait for readiness, run playbooks, verify |
| **3 - Full Pipeline** | `03-full-cicd.yml` | Push to main, workflow_dispatch | Run 01 then 02 |

### Manual Triggers

```bash
# Full pipeline
gh workflow run "3 - Full CI/CD Pipeline (Provision + Configure)" \
  --ref main \
  -f environment=dev

# Terraform plan only (view in logs)
gh workflow run "0 - Terraform Plan" --ref main -f environment=dev

# Destroy all infrastructure
gh workflow run "1 - Terraform Provision Infrastructure" \
  --ref main \
  -f action=destroy

# Ansible configure only (after manual Terraform apply)
gh workflow run "2 - Ansible Configure Instances" --ref main \
  -f environment=dev \
  -f limit="" \
  -f tags=""
```

---

## Local Development & Testing

```bash
# Initialize Terraform (one-time)
cd terraform
terraform init

# Validate syntax
terraform validate

# Plan with SSH key from GitHub
TF_VAR_ssh_public_key="$(gh secret view SSH_PUBLIC_KEY --repo OWNER/REPO)" \
  terraform plan -var-file="terraform.tfvars"

# Apply
TF_VAR_ssh_public_key="$(gh secret view SSH_PUBLIC_KEY --repo OWNER/REPO)" \
  terraform apply -var-file="terraform.tfvars" -auto-approve

# Test Ansible inventory (after Terraform apply)
cd ../ansible
ansible-inventory -i aws_ec2.yml --graph
ansible-inventory -i aws_ec2.yml --list | python3 -m json.tool

# Test connectivity
ansible tag_OS_Type_ubuntu -i aws_ec2.yml -m ping

# Run playbook against all hosts
ansible-playbook -i aws_ec2.yml playbooks/site.yml

# Run playbook against one OS type
ansible-playbook -i aws_ec2.yml playbooks/site.yml \
  --limit tag_OS_Type_ubuntu
```

---

## Enterprise Features

| Feature | Implementation | Benefit |
|---|---|---|
| **No long-lived AWS keys** | GitHub Actions OIDC with IAM role assumption | Eliminates credential rotation, eliminates leaked-key incidents |
| **Immutable audit trail** | Git history + GitHub Actions logs | Every change is attributed, timestamped, and reviewable |
| **Approval gates** | PR-based plan review for Terraform | No infrastructure change happens without peer review |
| **State encryption at rest** | S3 server-side encryption (AES-256) | Terraform state contains sensitive resource IDs and metadata |
| **State versioning** | S3 versioning + Object Lock | Recover from accidental state deletion or corruption |
| **IMDSv2 enforcement** | `http_tokens = "required"` on all instances | Prevents SSRF-based credential theft (CVE-2022-30181 mitigation) |
| **EBS encryption** | Root volume encryption with KMS option | Meets compliance requirements (HIPAA, PCI, SOC2) |
| **OS-specific security groups** | SSH (22) for Linux, WinRM (5986) + RDP (3389) for Windows | Minimal attack surface — Windows ports not exposed on Linux hosts |
| **Spot instance support** | Per-group spot pricing with persistent stop | Reduce costs 60-90% for fault-tolerant workloads |
| **CloudWatch monitoring** | Automatic agent install + metric alarms + SNS | No monitoring blind spots, proactive notification before outage |
| **Multi-OS from one inventory** | Single tfvars file supports 4 OS types | One source of truth for all server definitions across the org |
| **Dynamic Ansible inventory** | AWS API tag-based discovery with zero maintenance | No static host files, no manual IP management |
| **Windows + Linux in one pipeline** | Unified CI/CD with WinRM and SSH | Single workflow manages heterogeneous environments |
| **Windows password management** | EC2 GetPasswordData + auto-decryption | No hardcoded or stale Windows credentials |
| **Progressive readiness polling** | SSH (10 min) → WinRM (15 min) with timeouts | Pipeline does not fail if Windows bootstrapping is slow |
| **Alarm naming convention** | `EC2 <name>-<env>-<N>-{CPU,Memory,Disk}-Alerts` | Every alarm is uniquely identifiable in the AWS console |

---

## Troubleshooting

### Terraform

| Problem | Likely Cause | Solution |
|---|---|---|
| `Error: Invalid for_each argument` | Duplicate keys in server map | Ensure each server entry has a unique combination of role, os_type, and index |
| `Error: Failed to query available provider packages` | No internet or wrong region | Check AWS credentials and region in `terraform.tfvars` |
| `Error: creating IAM Role: MalformedPolicyDocument` | OIDC trust policy issue | Re-run `scripts/01.setup-aws-oidc.sh` |
| `Error: Bucket encryption disabled` | State bucket missing | Re-run `scripts/02.setup_s3-backend.sh` |
| `Plan shows destroy + create instead of update` | Changed a `for_each` key | Keys are immutable — you changed role, os_type, or index. Remove then add |

### Ansible

| Problem | Likely Cause | Solution |
|---|---|---|
| `Failed to connect via SSH` | Instance still booting, or security group missing | Check EC2 console, verify security group has port 22, wait 60s and retry |
| `WinRM connection refused` | configure-winrm.ps1 not finished | Windows instance can take 5-10 minutes to finish user_data. Check console output |
| `fatal: [ip]: UNREACHABLE!` | Wrong SSH key or user | Verify `ansible.cfg` private key path and `group_vars` SSH user |
| `"curl-minimal" conflicts with "curl"` | Amazon Linux 2023 package conflict | The `common` role handles this with `allowerasing`, but if you add `curl` directly use `state: absent` on `curl-minimal` first |
| `No inventory groups matched` | EC2 tags not propagated | Wait 2-3 minutes after Terraform apply for tags to sync with AWS API |
| `SELinux blocking nginx` | RHEL 9 SELinux enforcing | The `os_redhat.yml` playbook sets `httpd_can_network_connect` SELinux boolean |

### CI/CD

| Problem | Likely Cause | Solution |
|---|---|---|
| `Error: Unable to locate credentials` | OIDC role not configured | Check `AWS_IAM_ROLE_ARN` secret exists in repo |
| `Workflow run skipped` | Path filter did not match | Push must touch `terraform/`, `ansible/`, or `.github/` to trigger |
| `Ansible configure step fails with "Host key verification failed"` | Host key changed | The pipeline uses `StrictHostKeyChecking=no` in ansible.cfg |
| `Windows playbook fails on chocolatey install` | Outbound internet blocked | Windows instances need internet to download chocolatey and IIS is installed separately via Windows features |

---

## Cleanup

```bash
# Option 1: Via GitHub Actions (recommended)
gh workflow run "1 - Terraform Provision Infrastructure" \
  --ref main \
  -f action=destroy

# Option 2: Locally
cd terraform
terraform destroy -var-file="terraform.tfvars" -auto-approve

# Option 3: Full AWS teardown
./scripts/03.delete-aws-oidc.sh    # Remove OIDC provider + IAM role
./scripts/04.destroy-s3-backend.sh  # Remove S3 state bucket
```