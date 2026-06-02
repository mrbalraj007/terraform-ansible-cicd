#!/usr/bin/env python3
"""
Check if an Ansible inventory group exists and has hosts.
Usage: echo '<inventory-json>' | python3 check-inventory-group.py <group_name>
Returns exit code 0 if group exists with hosts, 1 otherwise.
"""
import json
import sys

group_name = sys.argv[1] if len(sys.argv) > 1 else ""
inv = json.load(sys.stdin)

if group_name in inv and inv[group_name].get("hosts"):
    sys.exit(0)
else:
    sys.exit(1)