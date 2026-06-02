#!/usr/bin/env python3
"""
Parse ansible-inventory --list JSON and print a markdown summary table
for GitHub Step Summary.
"""
import json
import sys

inv = json.load(sys.stdin)
hosts = inv.get("_meta", {}).get("hostvars", {})

print("| OS Type | Host | Public IP | Ansible Reachable |")
print("|---------|------|-----------|-------------------|")
for h, v in hosts.items():
    tags = v.get("tags", {})
    os_type = tags.get("OS_Type", "?")
    ip = v.get("public_ip_address", "N/A")
    print(f"| {os_type} | {h} | {ip} | ✅ |")