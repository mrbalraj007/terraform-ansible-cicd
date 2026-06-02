#!/usr/bin/env python3
"""
Convert terraform output JSON to markdown summary for GitHub Step Summary.
Called by the CI/CD pipeline after terraform apply.
"""
import json
import sys

data = json.load(sys.stdin)

if "deployment_summary" in data:
    print(data["deployment_summary"]["value"])

if "all_public_ips" in data:
    ips = data["all_public_ips"]["value"]
    print(f"\nTotal instances: {len(ips)}")
    print(f"Public IPs: {', '.join(ips)}")

if "windows_public_ips" in data:
    win_ips = data["windows_public_ips"]["value"]
    if win_ips:
        print(f"Windows IPs: {', '.join(win_ips)}")