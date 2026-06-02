#!/usr/bin/env python3
"""
Parse ansible-inventory --list JSON and print host details by OS, Role, Env.
"""
import json
import sys

inv = json.load(sys.stdin)
hosts = inv.get("_meta", {}).get("hostvars", {})
groups = {k: v for k, v in inv.items() if k != "_meta"}
print("Groups:", list(groups.keys()))
for h, v in hosts.items():
    tags = v.get("tags", {})
    print(
        f"  {h}  OS={tags.get('OS_Type','?')}  "
        f"Role={tags.get('Role','?')}  "
        f"Env={tags.get('Environment','?')}"
    )