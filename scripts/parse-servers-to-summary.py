#!/usr/bin/env python3
"""
Parse terraform.tfvars server definitions and output a GitHub Step Summary
markdown table. Called by the CI/CD pipeline.
"""
import re
import sys

TFFILE = "terraform.tfvars"

try:
    with open(TFFILE) as f:
        content = f.read()

    blocks = re.findall(r'\{([^}]+)\}', content)
    i = 0
    for block in blocks:
        name = re.search(r'name\s*=\s*"([^"]+)"', block)
        os_type = re.search(r'os_type\s*=\s*"([^"]+)"', block)
        itype = re.search(r'instance_type\s*=\s*"([^"]+)"', block)
        cnt = re.search(r'count\s*=\s*(\d+)', block)
        vol = re.search(r'volume_size\s*=\s*(\d+)', block)
        role = re.search(r'role\s*=\s*"([^"]+)"', block)
        if name or os_type:
            i += 1
            print(
                f'| {i} '
                f'| {(name.group(1) if name else "?")} '
                f'| {(os_type.group(1) if os_type else "?")} '
                f'| {(itype.group(1) if itype else "?")} '
                f'| {(cnt.group(1) if cnt else "1")} '
                f'| {(vol.group(1) if vol else "?")} '
                f'| {(role.group(1) if role else "?")} |'
            )

except Exception as e:
    print(f"Warning: could not parse servers: {e}", file=sys.stderr)