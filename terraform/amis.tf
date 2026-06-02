###############################################################################
# terraform/amis.tf
# Centralized AMI mapping per OS type per region
# Uses data sources for dynamic lookups but pin to specific AMIs for
# deterministic deployments. Update these when you want newer base images.
###############################################################################

locals {
  # ── AMI owner aliases ──────────────────────────────────────────────────
  ami_owners = {
    amazon_linux = "amazon"
    ubuntu       = "099720109477" # Canonical
    redhat       = "309956199498" # Red Hat
    windows      = "amazon"       # Amazon provides Windows AMIs
  }

  # ── AMI name filters ───────────────────────────────────────────────────
  ami_filters = {
    amazon_linux = {
      name      = "al2023-ami-*-kernel-6.1-x86_64"
      virt_type = "hvm"
    }
    ubuntu = {
      name      = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      virt_type = "hvm"
    }
    redhat = {
      name      = "RHEL-9.*_HVM-*-x86_64-*"
      virt_type = "hvm"
    }
    windows = {
      name      = "Windows_Server-2022-English-Full-Base-*"
      virt_type = "hvm"
    }
  }
}

# ──── Dynamic AMI data sources ─────────────────────────────────────────────
data "aws_ami" "this" {
  for_each    = local.ami_filters
  most_recent = true
  owners      = [local.ami_owners[each.key]]

  filter {
    name   = "name"
    values = [each.value.name]
  }

  filter {
    name   = "virtualization-type"
    values = [each.value.virt_type]
  }
}

# ──── Local AMI map (data source output) ────────────────────────────────────
locals {
  ami_ids = {
    for os, _ in local.ami_filters :
    os => data.aws_ami.this[os].id
  }

  ami_descriptions = {
    for os, _ in local.ami_filters :
    os => data.aws_ami.this[os].name
  }
}