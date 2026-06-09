#!/usr/bin/env python3
"""
Parse `terraform show -json` output and generate a markdown table
of planned resource changes for GitHub Actions step summary.

Usage:
    terraform show -json tfplan | python3 scripts/plan-resource-table.py

Reads from stdin when tfplan file path is passed:
    python3 scripts/plan-resource-table.py /path/to/tfplan
"""

import sys
import json
import re


def parse_resource_address(addr):
    """Parse a Terraform resource address into its components."""
    # module.server_group["app-ubuntu-1"].aws_instance.this[0]
    # or tls_private_key.ec2_key
    # or local_sensitive_file.private_key
    # or null_resource.upload_private_key

    result = {
        "module": None,
        "resource_type": None,
        "resource_name": None,
        "index": None,
        "full_name": addr,
    }

    m = re.match(r"module\.(.+?)\.(.+?)\[(.+?)\]$", addr)
    if m:
        result["module"] = m.group(1)  # e.g. "server_group"
        resource_part = m.group(2)      # e.g. "aws_instance.this"
        result["index"] = m.group(3)    # e.g. "0"
        parts = resource_part.rsplit(".", 1)
        result["resource_type"] = parts[0]
        result["resource_name"] = parts[1]
        return result

    # No module prefix: module.server_group["app-ubuntu-1"].aws_instance.this
    m = re.match(r"(module\.[^.]+)\.(.+)$", addr)
    if m:
        result["module"] = m.group(1)
        resource_part = m.group(2)
        parts = resource_part.rsplit(".", 1)
        result["resource_type"] = parts[0]
        result["resource_name"] = parts[1]
        return result

    # Root-level resources: tls_private_key.ec2_key
    if "." in addr:
        parts = addr.rsplit(".", 1)
        result["resource_type"] = parts[0]
        result["resource_name"] = parts[1]
    else:
        result["resource_name"] = addr

    return result


def extract_server_info(module_name):
    """Extract server group info from the module name (e.g. 'server_group["app-ubuntu-1"]')."""
    m = re.match(r'server_group\[(.+)\]', module_name)
    if m:
        return m.group(1)  # e.g. "app-ubuntu-1"
    return module_name


def get_instance_config(addr, changes):
    """Get instance configuration details from the planned changes."""
    # The full resource address in plan JSON includes [index] for counts
    # module.server_group["app-ubuntu-1"].aws_instance.this[0]
    base_addr = re.sub(r"\[\d+\]$", "", addr)

    change = changes.get(base_addr, {})
    if not change:
        return {}

    # Values are in change["after"] for create, change["before"] for destroy
    after = change.get("after", {})

    if isinstance(after, dict):
        return {
            "instance_type": after.get("instance_type", "—"),
            "ami": after.get("ami", "—"),
            "volume_size": after.get("root_block_device", [{}])[0].get("volume_size", "—") if after.get("root_block_device") else "—",
            "tags": after.get("tags", {}),
        }

    return {}


def main():
    # Read plan JSON from stdin or file argument
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            plan_data = json.load(f)
    else:
        plan_data = json.load(sys.stdin)

    # terraform show -json tfplan output structure:
    # { "changes": { "resource_changes": [ { "address", "actions": ["create"], ... }, ... ] } }
    changes_list = plan_data.get("changes", {}).get("resource_changes", [])

    # Group by module instance (e.g. server_group["app-ubuntu-1"])
    server_groups = {}
    other_changes = []

    for chg in changes_list:
        addr = chg.get("address", "")
        actions = chg.get("actions", [])
        action = actions[0] if actions else "no-op"

        parsed = parse_resource_address(addr)

        if parsed["module"] and parsed["module"].startswith("module."):
            module_key = parsed["module"].replace("module.", "")
            if module_key not in server_groups:
                server_groups[module_key] = []
            server_groups[module_key].append({
                **parsed,
                "action": action,
                "full_addr": addr,
            })
        else:
            other_changes.append({
                **parsed,
                "action": action,
                "full_addr": addr,
            })

    # Print server groups resource table
    print("### Planned Resource Changes\n")

    if server_groups:
        print("| # | Server Group | Resource | Action |")
        print("|---|--------------|----------|--------|")

        idx = 1
        for module_key, resources in sorted(server_groups.items()):
            for res in sorted(resources, key=lambda x: x["full_addr"]):
                action_icon = {
                    "create": "➕ Create",
                    "read": "📄 Read",
                    "update": "🔄 Update",
                    "delete": "🗑️  Delete",
                    "no-op": "— No change",
                }.get(res["action"], res["action"])

                print(f"| {idx} | `{module_key}` | `{res['resource_type']}.{res['resource_name']}` | {action_icon} |")
                idx += 1
    else:
        print("_No server group resources in plan._")

    # Print other resources (key pairs, TLS, etc.)
    if other_changes:
        print(f"\n### Infrastructure Resources\n")
        print("| Resource | Action |")
        print("|----------|--------|")
        for res in sorted(other_changes, key=lambda x: x["full_addr"]):
            action_icon = {
                "create": "➕ Create",
                "read": "📄 Read",
                "update": "🔄 Update",
                "delete": "🗑️  Delete",
                "no-op": "— No change",
            }.get(res["action"], res["action"])
            print(f"| `{res['resource_type']}.{res['resource_name']}` | {action_icon} |")


if __name__ == "__main__":
    main()