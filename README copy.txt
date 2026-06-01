# Terraform + Ansible CI/CD with GitHub Actions

## Overview

Provision EC2 instances with Terraform, then configure them automatically
using Ansible with **AWS EC2 Dynamic Inventory** — all running in GitHub Actions.

## Architecture

```
GitHub Push
    │
    ▼
┌─────────────────────────────────────┐
│  Workflow 1: Terraform Provision    │
│  ┌──────────┐  ┌──────────────────┐ │
│  │  Plan    │─▶│  Apply           │ │
│  └──────────┘  └──────────────────┘ │
└─────────────────────────────────────┘
    │ on success
    ▼
┌─────────────────────────────────────┐
│  Workflow 2: Ansible Configure      │
│  ┌──────────────────────────────┐   │
│  │  Dynamic Inventory (EC2 tags)│   │
│  │  tag_Role_web ──▶ webserver  │   │
│  │  tag_Role_app ──▶ appserver  │   │
│  └──────────────────────────────┘   │
└─────────────────────────────────────┘
```

## GitHub Secrets Required

| Secret | Description |
|--------|-------------|
| `AWS_IAM_ROLE_ARN` | IAM Role ARN for OIDC authentication |
| `SSH_PUBLIC_KEY` | Public key injected into EC2 via Terraform |
| `SSH_PRIVATE_KEY` | Private key used by Ansible to SSH into EC2 |

## Setup Steps

1. **Generate SSH keys**: `./scripts/generate-ssh-keys.sh`
2. **Setup AWS OIDC**: `./scripts/setup-aws-oidc.sh`
3. **Update S3 backend** in `terraform/main.tf`
4. **Add GitHub Secrets** (see table above)
5. **Push to main** — CI/CD runs automatically

## Project Structure

```
├── terraform/
│   ├── main.tf            # EC2, SG, Key Pair resources
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
├── ansible/
│   ├── aws_ec2.yml        # Dynamic inventory plugin config
│   ├── ansible.cfg
│   └── playbooks/
│       └── site.yml       # Master playbook
│   └── roles/
│       ├── webserver/     # Nginx setup
│       └── appserver/     # Java/app setup
├── scripts/
│   ├── generate-ssh-keys.sh
│   └── setup-aws-oidc.sh
└── .github/workflows/
    ├── 01-terraform-provision.yml
    ├── 02-ansible-configure.yml
    └── 03-full-cicd.yml   # Combined pipeline
```
