###############################################################################
# terraform/outputs.tf
# Aggregated outputs from all server groups
###############################################################################

# ──── Per-group outputs ─────────────────────────────────────────────────────

output "server_groups" {
  description = "Map of server group key to its module outputs"
  value = {
    for k, m in module.server_group : k => {
      instance_ids      = m.instance_ids
      public_ips        = m.public_ips
      private_ips       = m.private_ips
      admin_user        = m.admin_user
      os_type           = m.os_type
      role              = m.instance_role
      security_group_id = m.security_group_id
      eip_addresses     = m.eip_addresses
    }
  }
}

# ──── Flat aggregated lists (for simple consumption) ────────────────────────

output "all_instance_ids" {
  description = "Flat list of all EC2 instance IDs across all server groups"
  value       = flatten([for m in module.server_group : m.instance_ids])
}

output "all_public_ips" {
  description = "Flat list of all public IPs across all server groups"
  value       = flatten([for m in module.server_group : m.public_ips])
}

output "all_private_ips" {
  description = "Flat list of all private IPs across all server groups"
  value       = flatten([for m in module.server_group : m.private_ips])
}

# ──── OS-specific outputs (for Ansible targeting) ───────────────────────────

output "windows_public_ips" {
  description = "Public IPs of Windows instances (for WinRM-based Ansible)"
  value = flatten([
    for m in module.server_group : m.public_ips if m.os_type == "windows"
  ])
}

output "linux_public_ips" {
  description = "Public IPs of Linux instances (amazon_linux + ubuntu + redhat)"
  value = flatten([
    for m in module.server_group : m.public_ips if m.os_type != "windows"
  ])
}

# ──── Admin user map (for Ansible inventory generation) ─────────────────────

output "admin_user_map" {
  description = "Map of public IP to admin username per OS type"
  value = merge([
    for m in module.server_group : {
      for ip in m.public_ips : ip => m.admin_user
    }
  ]...)
}

# ──── Summary ───────────────────────────────────────────────────────────────

output "deployment_summary" {
  description = "Human-readable summary of the deployed infrastructure"
  value = join("\n", concat([
    "═══════════════════════════════════════════════════",
    "  Deployment Summary",
    "═══════════════════════════════════════════════════",
    "",
    ], flatten([
      for k, m in module.server_group : [
        "  Group: ${k}",
        "    OS:        ${m.os_type}",
        "    Role:      ${m.instance_role}",
        "    Admin:     ${m.admin_user}",
        "    Count:     ${length(m.instance_ids)}",
        "    Public IPs: ${join(", ", m.public_ips)}",
        "    SGRP:      ${m.security_group_id}",
        "",
      ]
  ])))
}