import { useState } from "react";

const steps = [
  {
    id: 1,
    phase: "PREREQS",
    title: "Prerequisites & Repo Setup",
    color: "#f59e0b",
    icon: "⚙️",
    content: {
      overview: "Before writing any code, get these in place. The whole pipeline depends on correct IAM + SSH credentials.",
      tasks: [
        {
          title: "Create GitHub Repository",
          code: `# Clone locally and set up structure
git clone https://github.com/your-org/terraform-ansible-cicd
cd terraform-ansible-cicd

# Create the folder structure
mkdir -p terraform ansible/{playbooks,roles/{webserver/{tasks,handlers,templates},appserver/tasks}} scripts .github/workflows`,
          lang: "bash",
        },
        {
          title: "Generate SSH Key Pair",
          desc: "Terraform injects the public key into EC2. Ansible uses the private key to connect.",
          code: `# Run the included helper script
chmod +x scripts/generate-ssh-keys.sh
./scripts/generate-ssh-keys.sh

# This creates:
#   keys/deployer_key       ← PRIVATE (→ GitHub Secret: SSH_PRIVATE_KEY)
#   keys/deployer_key.pub   ← PUBLIC  (→ GitHub Secret: SSH_PUBLIC_KEY)

# Add keys/ to .gitignore — NEVER commit the private key!`,
          lang: "bash",
        },
        {
          title: "Setup AWS OIDC (no long-lived keys)",
          desc: "Use OIDC instead of AWS_ACCESS_KEY_ID/SECRET. GitHub Actions gets short-lived tokens.",
          code: `# Edit scripts/setup-aws-oidc.sh first:
#   GITHUB_ORG="your-github-org"
#   GITHUB_REPO="your-repo-name"

chmod +x scripts/setup-aws-oidc.sh
./scripts/setup-aws-oidc.sh

# Output: AWS_IAM_ROLE_ARN = arn:aws:iam::123456789:role/github-actions-terraform-role`,
          lang: "bash",
        },
        {
          title: "Create S3 Backend + DynamoDB Lock Table",
          code: `# S3 bucket for Terraform state
aws s3api create-bucket \\
  --bucket your-tfstate-bucket \\
  --region ap-southeast-2 \\
  --create-bucket-configuration LocationConstraint=ap-southeast-2

aws s3api put-bucket-versioning \\
  --bucket your-tfstate-bucket \\
  --versioning-configuration Status=Enabled

# DynamoDB for state locking
aws dynamodb create-table \\
  --table-name terraform-lock \\
  --attribute-definitions AttributeName=LockID,AttributeType=S \\
  --key-schema AttributeName=LockID,KeyType=HASH \\
  --billing-mode PAY_PER_REQUEST \\
  --region ap-southeast-2`,
          lang: "bash",
        },
      ],
    },
  },
  {
    id: 2,
    phase: "SECRETS",
    title: "GitHub Secrets Configuration",
    color: "#ef4444",
    icon: "🔐",
    content: {
      overview: "Three secrets power the entire pipeline. Set these in GitHub → Settings → Secrets and Variables → Actions.",
      table: [
        { secret: "AWS_IAM_ROLE_ARN", value: "arn:aws:iam::ACCOUNT_ID:role/github-actions-terraform-role", source: "Output of setup-aws-oidc.sh" },
        { secret: "SSH_PUBLIC_KEY", value: "ssh-ed25519 AAAA... github-actions-deployer", source: "Contents of keys/deployer_key.pub" },
        { secret: "SSH_PRIVATE_KEY", value: "-----BEGIN OPENSSH PRIVATE KEY-----\\n...", source: "Full contents of keys/deployer_key" },
      ],
      tasks: [
        {
          title: "Add Secrets via GitHub CLI",
          code: `# Add all three secrets at once
gh secret set AWS_IAM_ROLE_ARN < <(echo "arn:aws:iam::123456789:role/github-actions-terraform-role")
gh secret set SSH_PUBLIC_KEY < keys/deployer_key.pub
gh secret set SSH_PRIVATE_KEY < keys/deployer_key

# Verify
gh secret list`,
          lang: "bash",
        },
        {
          title: "Optional: Create 'dev' Environment with Approval",
          desc: "Adds a manual approval gate before Terraform Apply runs. Go to Settings → Environments → New environment → dev → Add required reviewers.",
          code: `# Settings → Environments → dev
# ✅ Required reviewers: your-github-username
# This creates a pause point before terraform apply runs`,
          lang: "yaml",
        },
      ],
    },
  },
  {
    id: 3,
    phase: "TERRAFORM",
    title: "Terraform Infrastructure Code",
    color: "#8b5cf6",
    icon: "🏗️",
    content: {
      overview: "EC2 instances are tagged with Role=web and Role=app. These tags are exactly how Ansible's dynamic inventory groups the hosts.",
      tasks: [
        {
          title: "terraform/main.tf — Key tagging pattern",
          desc: "The Role tag is the bridge between Terraform and Ansible. Ansible groups hosts as tag_Role_web and tag_Role_app.",
          code: `# Web instances — Ansible will see these as group: tag_Role_web
resource "aws_instance" "web" {
  count         = var.web_instance_count
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.deployer.key_name

  tags = merge(var.common_tags, {
    Name        = "\${var.project_name}-web-\${count.index + 1}"
    Role        = "web"          # ← Ansible uses THIS tag
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
  })
}

# App instances — Ansible group: tag_Role_app
resource "aws_instance" "app" {
  count         = var.app_instance_count
  # ... same structure, Role = "app"
  tags = merge(var.common_tags, {
    Role = "app"                 # ← Different group
  })
}`,
          lang: "hcl",
        },
        {
          title: "terraform/variables.tf — SSH key as variable",
          code: `variable "ssh_public_key" {
  description = "SSH public key — stored as GitHub Secret SSH_PUBLIC_KEY"
  type        = string
  sensitive   = true            # Won't appear in plan output
}

# Injected at runtime:
# TF_VAR_ssh_public_key: \${{ secrets.SSH_PUBLIC_KEY }}`,
          lang: "hcl",
        },
        {
          title: "Update backend in main.tf",
          desc: "Replace the placeholder with your actual S3 bucket name.",
          code: `# terraform/main.tf — update this block:
backend "s3" {
  bucket         = "your-tfstate-bucket"   # ← YOUR bucket name
  key            = "terraform-ansible/terraform.tfstate"
  region         = "ap-southeast-2"
  dynamodb_table = "terraform-lock"
  encrypt        = true
}`,
          lang: "hcl",
        },
      ],
    },
  },
  {
    id: 4,
    phase: "ANSIBLE",
    title: "Ansible Dynamic Inventory",
    color: "#10b981",
    icon: "📋",
    content: {
      overview: "The aws_ec2.yml plugin queries AWS in real time to build the inventory — no static IP lists needed. Groups are built from EC2 tags.",
      tasks: [
        {
          title: "ansible/aws_ec2.yml — Dynamic inventory config",
          desc: "This replaces a traditional hosts.ini file. Ansible queries AWS on every run.",
          code: `plugin: amazon.aws.aws_ec2

regions:
  - ap-southeast-2

# Only return running instances that belong to this project
filters:
  instance-state-name: running
  "tag:Project": tf-ansible-demo
  "tag:ManagedBy": Terraform

# Use public IP as the hostname
hostnames:
  - public-ip-address

# Build groups from EC2 tags  ← THIS IS THE KEY PART
keyed_groups:
  - key: tags.Role          # Creates: tag_Role_web, tag_Role_app
    prefix: tag_Role
    separator: "_"

# Set connection variables per host
compose:
  ansible_host: public_ip_address
  ansible_user: "ec2-user"`,
          lang: "yaml",
        },
        {
          title: "Test dynamic inventory locally",
          code: `cd ansible/

# Install requirements
pip install boto3 botocore
ansible-galaxy collection install amazon.aws

# View all discovered hosts
ansible-inventory -i aws_ec2.yml --list

# View as a tree
ansible-inventory -i aws_ec2.yml --graph

# Expected output:
# @all:
#   @tag_Role_web:
#     13.55.xx.xx
#     13.54.xx.xx
#   @tag_Role_app:
#     54.66.xx.xx`,
          lang: "bash",
        },
        {
          title: "ansible/playbooks/site.yml — Target groups",
          code: `---
# Groups match the keyed_groups in aws_ec2.yml
- name: Configure Web Servers
  hosts: tag_Role_web       # ← All instances with tag Role=web
  become: true
  roles:
    - webserver              # Installs + configures Nginx

- name: Configure App Servers
  hosts: tag_Role_app       # ← All instances with tag Role=app
  become: true
  roles:
    - appserver              # Installs Java, creates app dir`,
          lang: "yaml",
        },
      ],
    },
  },
  {
    id: 5,
    phase: "WORKFLOWS",
    title: "GitHub Actions Workflows",
    color: "#3b82f6",
    icon: "🔄",
    content: {
      overview: "Three workflows: Workflow 1 (Terraform) triggers Workflow 2 (Ansible) automatically on success. Workflow 3 is a combined manual trigger.",
      tasks: [
        {
          title: "01-terraform-provision.yml — Plan then Apply",
          code: `# Triggered on: push to main (terraform/** paths) or manual
on:
  push:
    branches: [main]
    paths:
      - "terraform/**"
  workflow_dispatch:
    inputs:
      action: { type: choice, options: [plan, apply, destroy] }

jobs:
  terraform-plan:    # Always runs — validates and creates plan artifact
  
  terraform-apply:   # Only runs on main branch push or manual 'apply'
    needs: terraform-plan
    environment: dev  # Requires manual approval if env is configured
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: \${{ secrets.AWS_IAM_ROLE_ARN }}  # OIDC — no keys!
      
      - name: Terraform Apply
        env:
          TF_VAR_ssh_public_key: \${{ secrets.SSH_PUBLIC_KEY }}
        run: terraform apply -auto-approve tfplan`,
          lang: "yaml",
        },
        {
          title: "02-ansible-configure.yml — Dynamic inventory + Playbook",
          code: `# Auto-triggered when Workflow 1 succeeds
on:
  workflow_run:
    workflows: ["1 - Terraform Provision Infrastructure"]
    types: [completed]
    branches: [main]
  workflow_dispatch:
    inputs:
      limit: { description: "ansible --limit", default: "all" }

jobs:
  ansible-configure:
    if: github.event.workflow_run.conclusion == 'success'
    steps:
      - name: Install Ansible + AWS deps
        run: pip install ansible boto3 botocore

      - name: Write SSH private key
        run: |
          mkdir -p ~/.ssh
          echo "\${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/deployer_key
          chmod 600 ~/.ssh/deployer_key

      - name: Wait for EC2 readiness
        run: sleep 30

      - name: Test dynamic inventory
        run: ansible-inventory -i aws_ec2.yml --graph

      - name: Ping all hosts
        run: ansible all -i aws_ec2.yml -m ping

      - name: Run playbook
        run: |
          ansible-playbook -i aws_ec2.yml playbooks/site.yml \\
            --private-key ~/.ssh/deployer_key -v`,
          lang: "yaml",
        },
        {
          title: "03-full-cicd.yml — One-click combined pipeline",
          code: `# Manual trigger — provisions AND configures in sequence
on:
  workflow_dispatch:
    inputs:
      environment: { type: choice, options: [dev, staging, prod] }

jobs:
  provision:
    uses: ./.github/workflows/01-terraform-provision.yml
    secrets: inherit

  configure:
    needs: provision          # Waits for Terraform to finish
    uses: ./.github/workflows/02-ansible-configure.yml
    secrets: inherit`,
          lang: "yaml",
        },
      ],
    },
  },
  {
    id: 6,
    phase: "RUN",
    title: "Run the Pipeline",
    color: "#06b6d4",
    icon: "🚀",
    content: {
      overview: "Everything is wired up. Here's the exact sequence to trigger a full deployment from scratch.",
      tasks: [
        {
          title: "First-time deploy",
          code: `# 1. Push terraform changes to trigger auto-pipeline
git add terraform/
git commit -m "feat: initial EC2 infrastructure"
git push origin main

# GitHub Actions automatically runs:
#   → Workflow 1: terraform plan → (approval) → terraform apply
#   → Workflow 2: ansible-inventory --graph → ping → playbook

# OR: Manual combined trigger
# GitHub UI → Actions → "3 - Full CI/CD Pipeline" → Run workflow`,
          lang: "bash",
        },
        {
          title: "Re-run Ansible only (no infra changes)",
          code: `# GitHub UI → Actions → "2 - Ansible Configure Instances"
# → Run workflow → limit: "all" or "tag_Role_web"

# OR via CLI:
gh workflow run 02-ansible-configure.yml \\
  -f limit=tag_Role_web \\
  -f tags=nginx`,
          lang: "bash",
        },
        {
          title: "Verify deployment",
          code: `# SSH into a web instance to check Nginx
ssh -i keys/deployer_key ec2-user@<public-ip>
sudo systemctl status nginx

# Or check from your machine:
curl http://<public-ip>
# Expected: "Deployed by Ansible via GitHub Actions"

# View inventory from runner (in logs):
ansible-inventory -i aws_ec2.yml --graph
# @all:
#   @tag_Role_web:
#     13.55.x.x   ← auto-discovered!`,
          lang: "bash",
        },
        {
          title: "Destroy infrastructure",
          code: `# GitHub UI → Actions → "1 - Terraform Provision Infrastructure"
# → Run workflow → action: destroy

# This tears down ALL EC2 instances created by Terraform`,
          lang: "bash",
        },
      ],
    },
  },
];

const architectureDiagram = [
  { from: "Git Push (terraform/**)", to: "Workflow 1: Terraform", color: "#8b5cf6" },
  { from: "Workflow 1: Terraform", to: "Plan → Approve → Apply", color: "#8b5cf6" },
  { from: "Plan → Approve → Apply", to: "EC2 web-1, web-2 (Role=web)", color: "#10b981" },
  { from: "Plan → Approve → Apply", to: "EC2 app-1 (Role=app)", color: "#10b981" },
  { from: "Workflow 1 succeeds", to: "Workflow 2: Ansible (auto-triggered)", color: "#3b82f6" },
  { from: "Workflow 2: Ansible (auto-triggered)", to: "aws_ec2 plugin → tag_Role_web group", color: "#3b82f6" },
  { from: "Workflow 2: Ansible (auto-triggered)", to: "aws_ec2 plugin → tag_Role_app group", color: "#3b82f6" },
  { from: "aws_ec2 plugin → tag_Role_web group", to: "webserver role → Nginx", color: "#f59e0b" },
  { from: "aws_ec2 plugin → tag_Role_app group", to: "appserver role → Java", color: "#f59e0b" },
];

function CodeBlock({ code, lang }) {
  const [copied, setCopied] = useState(false);
  const copy = () => {
    navigator.clipboard.writeText(code);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };
  return (
    <div style={{ position: "relative", marginTop: 12 }}>
      <button
        onClick={copy}
        style={{
          position: "absolute", top: 8, right: 8, zIndex: 10,
          background: copied ? "#10b981" : "#374151",
          color: "#fff", border: "none", borderRadius: 4,
          padding: "3px 10px", fontSize: 11, cursor: "pointer",
          fontFamily: "monospace",
        }}
      >
        {copied ? "✓ copied" : "copy"}
      </button>
      <pre style={{
        background: "#0f172a", color: "#e2e8f0",
        borderRadius: 8, padding: "16px 14px", fontSize: 12,
        overflowX: "auto", lineHeight: 1.6, margin: 0,
        border: "1px solid #1e293b",
        fontFamily: "'JetBrains Mono', 'Fira Code', 'Courier New', monospace",
      }}>
        <code>{code.trim()}</code>
      </pre>
    </div>
  );
}

function SecretsTable({ table }) {
  return (
    <div style={{ overflowX: "auto", marginTop: 12 }}>
      <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}>
        <thead>
          <tr style={{ background: "#1e293b" }}>
            {["GitHub Secret Name", "Value", "Where to get it"].map(h => (
              <th key={h} style={{ padding: "8px 12px", textAlign: "left", color: "#94a3b8", fontWeight: 600, borderBottom: "1px solid #334155" }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {table.map((row, i) => (
            <tr key={i} style={{ background: i % 2 === 0 ? "#0f172a" : "#111827" }}>
              <td style={{ padding: "8px 12px", color: "#f59e0b", fontFamily: "monospace", fontWeight: 700 }}>{row.secret}</td>
              <td style={{ padding: "8px 12px", color: "#94a3b8", fontFamily: "monospace", fontSize: 11 }}>{row.value}</td>
              <td style={{ padding: "8px 12px", color: "#64748b" }}>{row.source}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default function App() {
  const [activeStep, setActiveStep] = useState(1);
  const [expandedTask, setExpandedTask] = useState(null);
  const [showArch, setShowArch] = useState(false);

  const step = steps.find(s => s.id === activeStep);

  return (
    <div style={{
      minHeight: "100vh",
      background: "#0a0f1e",
      color: "#e2e8f0",
      fontFamily: "'Segoe UI', system-ui, sans-serif",
    }}>
      {/* Header */}
      <div style={{
        background: "linear-gradient(135deg, #0f172a 0%, #1e1b4b 100%)",
        borderBottom: "1px solid #1e293b",
        padding: "20px 24px",
      }}>
        <div style={{ maxWidth: 900, margin: "0 auto" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 6 }}>
            <span style={{ fontSize: 22 }}>🚀</span>
            <h1 style={{ margin: 0, fontSize: 20, fontWeight: 700, color: "#f1f5f9" }}>
              Terraform + Ansible CI/CD
            </h1>
            <span style={{
              background: "#1e3a5f", color: "#60a5fa", fontSize: 11,
              padding: "2px 8px", borderRadius: 12, fontWeight: 600,
            }}>GitHub Actions</span>
          </div>
          <p style={{ margin: 0, color: "#64748b", fontSize: 13 }}>
            EC2 provisioning with Terraform → Ansible dynamic inventory → automated configuration
          </p>
          <button
            onClick={() => setShowArch(!showArch)}
            style={{
              marginTop: 12, background: showArch ? "#1e3a5f" : "transparent",
              border: "1px solid #334155", color: "#60a5fa",
              padding: "5px 14px", borderRadius: 6, cursor: "pointer",
              fontSize: 12, fontWeight: 600,
            }}
          >
            {showArch ? "▼ Hide Architecture" : "▶ View Architecture Flow"}
          </button>
        </div>
      </div>

      {/* Architecture */}
      {showArch && (
        <div style={{ background: "#0d1117", borderBottom: "1px solid #1e293b", padding: "16px 24px" }}>
          <div style={{ maxWidth: 900, margin: "0 auto" }}>
            <h3 style={{ margin: "0 0 12px", fontSize: 13, color: "#94a3b8", fontWeight: 600, textTransform: "uppercase", letterSpacing: 1 }}>Pipeline Flow</h3>
            <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
              {architectureDiagram.map((item, i) => (
                <div key={i} style={{ display: "flex", alignItems: "center", gap: 4 }}>
                  <span style={{
                    background: "#1e293b", border: `1px solid ${item.color}33`,
                    color: item.color, padding: "4px 10px", borderRadius: 4,
                    fontSize: 11, fontWeight: 500,
                  }}>{item.from}</span>
                  <span style={{ color: "#475569", fontSize: 14 }}>→</span>
                  {i === architectureDiagram.length - 1 && (
                    <span style={{
                      background: "#1e293b", border: `1px solid ${item.color}33`,
                      color: item.color, padding: "4px 10px", borderRadius: 4,
                      fontSize: 11, fontWeight: 500,
                    }}>{item.to}</span>
                  )}
                </div>
              ))}
            </div>
          </div>
        </div>
      )}

      <div style={{ maxWidth: 900, margin: "0 auto", padding: "24px 16px", display: "flex", gap: 20 }}>
        {/* Step sidebar */}
        <div style={{ width: 200, flexShrink: 0 }}>
          <div style={{ fontSize: 11, color: "#475569", fontWeight: 700, textTransform: "uppercase", letterSpacing: 1, marginBottom: 10 }}>Steps</div>
          {steps.map(s => (
            <button
              key={s.id}
              onClick={() => { setActiveStep(s.id); setExpandedTask(null); }}
              style={{
                display: "block", width: "100%", textAlign: "left",
                background: activeStep === s.id ? "#1e293b" : "transparent",
                border: activeStep === s.id ? `1px solid ${s.color}44` : "1px solid transparent",
                borderLeft: activeStep === s.id ? `3px solid ${s.color}` : "3px solid transparent",
                borderRadius: 6, padding: "10px 12px", cursor: "pointer",
                marginBottom: 4, transition: "all 0.15s",
              }}
            >
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{
                  width: 20, height: 20, borderRadius: "50%",
                  background: activeStep === s.id ? s.color : "#1e293b",
                  border: `1px solid ${s.color}`,
                  display: "flex", alignItems: "center", justifyContent: "center",
                  fontSize: 10, color: activeStep === s.id ? "#000" : s.color,
                  fontWeight: 700, flexShrink: 0,
                }}>{s.id}</span>
                <div>
                  <div style={{ fontSize: 10, color: activeStep === s.id ? s.color : "#475569", fontWeight: 700, textTransform: "uppercase", letterSpacing: 0.5 }}>{s.phase}</div>
                  <div style={{ fontSize: 12, color: activeStep === s.id ? "#e2e8f0" : "#94a3b8", lineHeight: 1.3 }}>{s.title}</div>
                </div>
              </div>
            </button>
          ))}

          {/* Nav buttons */}
          <div style={{ marginTop: 16, display: "flex", gap: 6 }}>
            <button
              onClick={() => setActiveStep(Math.max(1, activeStep - 1))}
              disabled={activeStep === 1}
              style={{
                flex: 1, padding: "7px 0", background: "#1e293b",
                border: "1px solid #334155", color: activeStep === 1 ? "#475569" : "#94a3b8",
                borderRadius: 6, cursor: activeStep === 1 ? "default" : "pointer", fontSize: 14,
              }}
            >←</button>
            <button
              onClick={() => setActiveStep(Math.min(steps.length, activeStep + 1))}
              disabled={activeStep === steps.length}
              style={{
                flex: 1, padding: "7px 0", background: "#1e293b",
                border: "1px solid #334155", color: activeStep === steps.length ? "#475569" : "#94a3b8",
                borderRadius: 6, cursor: activeStep === steps.length ? "default" : "pointer", fontSize: 14,
              }}
            >→</button>
          </div>
        </div>

        {/* Main content */}
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{
            background: "#0d1117", borderRadius: 10,
            border: `1px solid ${step.color}22`,
            overflow: "hidden",
          }}>
            {/* Step header */}
            <div style={{
              background: `linear-gradient(135deg, ${step.color}11, ${step.color}05)`,
              borderBottom: `1px solid ${step.color}22`,
              padding: "16px 20px",
              display: "flex", alignItems: "center", gap: 12,
            }}>
              <span style={{ fontSize: 24 }}>{step.icon}</span>
              <div>
                <div style={{ fontSize: 11, color: step.color, fontWeight: 700, textTransform: "uppercase", letterSpacing: 1 }}>
                  Step {step.id} / {steps.length} — {step.phase}
                </div>
                <h2 style={{ margin: 0, fontSize: 16, color: "#f1f5f9" }}>{step.title}</h2>
              </div>
            </div>

            <div style={{ padding: "16px 20px" }}>
              {/* Overview */}
              <div style={{
                background: "#1e293b", borderLeft: `3px solid ${step.color}`,
                padding: "10px 14px", borderRadius: "0 6px 6px 0",
                marginBottom: 16, fontSize: 13, color: "#94a3b8", lineHeight: 1.6,
              }}>
                {step.content.overview}
              </div>

              {/* Secrets table */}
              {step.content.table && <SecretsTable table={step.content.table} />}

              {/* Tasks */}
              {step.content.tasks.map((task, i) => (
                <div
                  key={i}
                  style={{
                    background: "#111827",
                    border: "1px solid #1e293b",
                    borderRadius: 8, marginTop: 12, overflow: "hidden",
                  }}
                >
                  <button
                    onClick={() => setExpandedTask(expandedTask === `${activeStep}-${i}` ? null : `${activeStep}-${i}`)}
                    style={{
                      width: "100%", textAlign: "left",
                      background: "none", border: "none",
                      padding: "12px 16px", cursor: "pointer",
                      display: "flex", justifyContent: "space-between", alignItems: "center",
                    }}
                  >
                    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                      <span style={{
                        width: 22, height: 22, borderRadius: "50%",
                        background: step.color, color: "#000",
                        display: "flex", alignItems: "center", justifyContent: "center",
                        fontSize: 11, fontWeight: 700, flexShrink: 0,
                      }}>{i + 1}</span>
                      <span style={{ fontSize: 13, fontWeight: 600, color: "#e2e8f0" }}>{task.title}</span>
                    </div>
                    <span style={{ color: "#475569", fontSize: 16 }}>
                      {expandedTask === `${activeStep}-${i}` ? "▲" : "▼"}
                    </span>
                  </button>

                  {expandedTask === `${activeStep}-${i}` && (
                    <div style={{ padding: "0 16px 16px" }}>
                      {task.desc && (
                        <p style={{ margin: "0 0 8px", fontSize: 12, color: "#64748b", lineHeight: 1.6 }}>{task.desc}</p>
                      )}
                      <CodeBlock code={task.code} lang={task.lang} />
                    </div>
                  )}
                </div>
              ))}
            </div>
          </div>

          {/* Progress bar */}
          <div style={{ marginTop: 16, display: "flex", gap: 4 }}>
            {steps.map(s => (
              <div
                key={s.id}
                onClick={() => setActiveStep(s.id)}
                style={{
                  flex: 1, height: 4, borderRadius: 2, cursor: "pointer",
                  background: s.id <= activeStep ? s.color : "#1e293b",
                  transition: "background 0.2s",
                }}
              />
            ))}
          </div>
          <div style={{ textAlign: "right", fontSize: 11, color: "#475569", marginTop: 4 }}>
            {activeStep} / {steps.length} steps
          </div>
        </div>
      </div>
    </div>
  );
}
