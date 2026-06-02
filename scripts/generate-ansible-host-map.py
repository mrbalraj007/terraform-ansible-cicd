#!/usr/bin/env python3
"""
Generate ansible_user mapping from Terraform outputs for use alongside
the AWS EC2 dynamic inventory plugin.
"""
import json
import os
import sys

data = json.load(sys.stdin)
output_dir = os.environ.get(
    "ANSIBLE_GROUP_VARS_DIR",
    os.path.join(os.path.dirname(__file__), "..", "ansible", "group_vars"),
)
os.makedirs(output_dir, exist_ok=True)

if "admin_user_map" in data:
    admin_map = data["admin_user_map"]["value"]
    with open(os.path.join(output_dir, "generated_host_map.yml"), "w") as f:
        f.write("# Auto-generated from Terraform output\n")
        f.write("# Maps public IPs to their admin username\n")
        for ip, user in sorted(admin_map.items()):
            f.write(f"{ip}: {user}\n")
    print(f"Generated admin user map: {len(admin_map)} entries")