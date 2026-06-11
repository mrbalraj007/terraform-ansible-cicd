#!/usr/bin/env python3
"""
Extract IPs from Ansible inventory JSON for one or more group names.
Usage: python3 get-inventory-ips.py <group1> [group2] ... < /tmp/ansible-inventory.json
Output: space-separated list of host IPs
"""
import json
import sys

groups = sys.argv[1:] if len(sys.argv) > 1 else []
inventory = json.load(sys.stdin)

hosts = []
for g in groups:
    if g in inventory:
        hosts.extend(inventory[g].get("hosts", []))

print(" ".join(hosts))