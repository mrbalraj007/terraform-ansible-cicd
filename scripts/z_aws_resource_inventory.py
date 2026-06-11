#!/usr/bin/env python3
"""
aws_resource_inventory.py
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
READ-ONLY script — zero writes to AWS.
Queries CloudTrail (via S3 logs) for ALL resource creation events
in the last 6 months (Jan 2026 → today), enriches with live AWS
metadata, and saves a CSV locally.

Supported resource types discovered from CloudTrail:
  • EC2 Instances           (RunInstances)
  • S3 Buckets              (CreateBucket)
  • RDS Instances           (CreateDBInstance)
  • Lambda Functions        (CreateFunction20150331 / CreateFunction)
  • IAM Users               (CreateUser)
  • IAM Roles               (CreateRole)
  • Security Groups         (CreateSecurityGroup)
  • VPCs                    (CreateVpc)
  • Subnets                 (CreateSubnet)
  • EBS Volumes             (CreateVolume)
  • EKS Clusters            (CreateCluster)
  • CloudFormation Stacks   (CreateStack)
  • DynamoDB Tables         (CreateTable)
  • SNS Topics              (CreateTopic)
  • SQS Queues              (CreateQueue)
  • Elastic Load Balancers  (CreateLoadBalancer)
  • Auto Scaling Groups     (CreateAutoScalingGroup)
  • ECR Repositories        (CreateRepository)
  • KMS Keys                (CreateKey)
  • Secrets Manager Secrets (CreateSecret)

Usage:
  # Minimal — auto-detects account, uses default region
  python3 aws_resource_inventory.py --bucket my-cloudtrail-bucket

  # Full options
  python3 aws_resource_inventory.py \
    --bucket   my-cloudtrail-bucket \
    --region   ap-southeast-2 \
    --profile  my-aws-profile \
    --start    2026-01-01 \
    --end      2026-06-11 \
    --output   aws_inventory_jan_jun2026.csv

  # Org trail with custom S3 prefix
  python3 aws_resource_inventory.py \
    --bucket my-cloudtrail-bucket \
    --prefix MyOrg/AWSLogs/123456789012/CloudTrail/ap-southeast-2

IAM permissions required (READ-ONLY):
  s3:GetObject, s3:ListBucket
  ec2:DescribeInstances, ec2:DescribeVolumes, ec2:DescribeSecurityGroups
  ec2:DescribeVpcs, ec2:DescribeSubnets
  rds:DescribeDBInstances
  lambda:GetFunction
  iam:GetUser, iam:GetRole
  eks:DescribeCluster
  dynamodb:DescribeTable
  sts:GetCallerIdentity
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"""

import boto3
import csv
import gzip
import json
import argparse
import sys
from datetime import datetime, timezone, timedelta
from botocore.exceptions import ClientError

# ─────────────────────────────────────────────────────────────────────
# EVENT MAP — CloudTrail eventName → resource type label
# ─────────────────────────────────────────────────────────────────────
EVENT_MAP = {
    "RunInstances":                   "EC2 Instance",
    "CreateBucket":                   "S3 Bucket",
    "CreateDBInstance":               "RDS Instance",
    "CreateFunction20150331":         "Lambda Function",
    "CreateFunction":                 "Lambda Function",
    "CreateUser":                     "IAM User",
    "CreateRole":                     "IAM Role",
    "CreateSecurityGroup":            "Security Group",
    "CreateVpc":                      "VPC",
    "CreateSubnet":                   "Subnet",
    "CreateVolume":                   "EBS Volume",
    "CreateCluster":                  "EKS Cluster",
    "CreateStack":                    "CloudFormation Stack",
    "CreateTable":                    "DynamoDB Table",
    "CreateTopic":                    "SNS Topic",
    "CreateQueue":                    "SQS Queue",
    "CreateLoadBalancer":             "Load Balancer",
    "CreateAutoScalingGroup":         "Auto Scaling Group",
    "CreateRepository":               "ECR Repository",
    "CreateKey":                      "KMS Key",
    "CreateSecret":                   "Secrets Manager Secret",
}

# ─────────────────────────────────────────────────────────────────────
# STEP 1 — List S3 keys for the date range
# ─────────────────────────────────────────────────────────────────────
def list_log_keys(s3_client, bucket, prefix, start_dt, end_dt):
    keys    = []
    current = start_dt.replace(hour=0, minute=0, second=0)

    print(f"\n📁 Listing CloudTrail log files in S3 ...")
    print(f"   Bucket : s3://{bucket}/{prefix}/")
    print(f"   Range  : {start_dt.date()} → {end_dt.date()}")

    while current <= end_dt:
        day_prefix = f"{prefix}/{current.strftime('%Y/%m/%d')}/"
        paginator  = s3_client.get_paginator("list_objects_v2")
        try:
            for page in paginator.paginate(Bucket=bucket, Prefix=day_prefix):
                for obj in page.get("Contents", []):
                    if obj["Key"].endswith(".json.gz"):
                        keys.append(obj["Key"])
        except ClientError as e:
            print(f"   ⚠️  Cannot list {day_prefix}: {e.response['Error']['Message']}")
        current += timedelta(days=1)

    print(f"   Found  : {len(keys)} log files")
    return keys


# ─────────────────────────────────────────────────────────────────────
# STEP 2 — Parse .json.gz from S3 → extract resource creation events
# ─────────────────────────────────────────────────────────────────────
def parse_log_file(s3_client, bucket, key):
    try:
        obj     = s3_client.get_object(Bucket=bucket, Key=key)
        content = gzip.decompress(obj["Body"].read())
        records = json.loads(content).get("Records", [])
        return [r for r in records if r.get("eventName") in EVENT_MAP]
    except Exception as e:
        print(f"   ⚠️  Skipping {key}: {e}")
        return []


def extract_resource_id(event):
    """
    Pull the primary resource identifier from a CloudTrail event.
    Each service puts it in a different location in responseElements.
    """
    name  = event.get("eventName", "")
    resp  = event.get("responseElements") or {}
    req   = event.get("requestParameters") or {}

    if name == "RunInstances":
        items = resp.get("instancesSet", {}).get("items", [])
        return [i.get("instanceId", "") for i in items if i.get("instanceId", "").startswith("i-")]

    if name == "CreateBucket":
        return [req.get("bucketName", resp.get("bucketName", "N/A"))]

    if name == "CreateDBInstance":
        return [resp.get("dBInstanceIdentifier", req.get("dBInstanceIdentifier", "N/A"))]

    if name in ("CreateFunction20150331", "CreateFunction"):
        return [resp.get("functionName", req.get("functionName", "N/A"))]

    if name == "CreateUser":
        return [resp.get("user", {}).get("userName", req.get("userName", "N/A"))]

    if name == "CreateRole":
        return [resp.get("role", {}).get("roleName", req.get("roleName", "N/A"))]

    if name == "CreateSecurityGroup":
        return [resp.get("groupId", req.get("groupName", "N/A"))]

    if name == "CreateVpc":
        return [resp.get("vpc", {}).get("vpcId", "N/A")]

    if name == "CreateSubnet":
        return [resp.get("subnet", {}).get("subnetId", "N/A")]

    if name == "CreateVolume":
        return [resp.get("volumeId", "N/A")]

    if name == "CreateCluster":
        return [resp.get("cluster", {}).get("name", req.get("name", "N/A"))]

    if name == "CreateStack":
        return [resp.get("stackId", req.get("stackName", "N/A"))]

    if name == "CreateTable":
        return [resp.get("tableDescription", {}).get("tableName", req.get("tableName", "N/A"))]

    if name == "CreateTopic":
        return [resp.get("topicArn", "N/A")]

    if name == "CreateQueue":
        return [resp.get("queueUrl", "N/A")]

    if name == "CreateLoadBalancer":
        lbs = resp.get("loadBalancers", [])
        return [lb.get("loadBalancerName", lb.get("loadBalancerArn", "N/A")) for lb in lbs] if lbs else ["N/A"]

    if name == "CreateAutoScalingGroup":
        return [req.get("autoScalingGroupName", "N/A")]

    if name == "CreateRepository":
        return [resp.get("repository", {}).get("repositoryName", req.get("repositoryName", "N/A"))]

    if name == "CreateKey":
        return [resp.get("keyMetadata", {}).get("keyId", "N/A")]

    if name == "CreateSecret":
        return [resp.get("name", req.get("name", "N/A"))]

    return ["N/A"]


def collect_events(s3_client, bucket, keys, start_dt, end_dt):
    """
    Returns list of dicts — one per resource created.
    """
    rows  = []
    total = len(keys)
    seen  = set()  # deduplicate (resource_id + event_time)

    print(f"\n🔍 Scanning {total} log files for resource creation events ...")

    for i, key in enumerate(keys, 1):
        if i % 50 == 0 or i == total:
            print(f"   [{i}/{total}] processed — {len(rows)} resources found so far")

        for event in parse_log_file(s3_client, bucket, key):

            # Parse and validate timestamp
            try:
                event_time = datetime.strptime(
                    event.get("eventTime", ""), "%Y-%m-%dT%H:%M:%SZ"
                ).replace(tzinfo=timezone.utc)
            except ValueError:
                continue

            if not (start_dt <= event_time <= end_dt):
                continue

            event_name    = event.get("eventName", "N/A")
            resource_type = EVENT_MAP.get(event_name, "Unknown")
            aws_region    = event.get("awsRegion", "N/A")

            # Creator identity
            uid     = event.get("userIdentity", {})
            creator = (
                uid.get("arn") or
                uid.get("userName") or
                uid.get("principalId") or
                uid.get("type", "unknown")
            )

            # Source IP (useful for auditing)
            source_ip = event.get("sourceIPAddress", "N/A")

            # Error check — skip failed API calls
            if event.get("errorCode"):
                continue

            resource_ids = extract_resource_id(event)

            for rid in resource_ids:
                if not rid or rid == "N/A":
                    continue
                dedup_key = f"{rid}_{event_time.isoformat()}"
                if dedup_key in seen:
                    continue
                seen.add(dedup_key)

                rows.append({
                    "Resource Type":  resource_type,
                    "Resource ID":    rid,
                    "Resource Name":  "N/A",          # enriched in Step 3
                    "Region":         aws_region,
                    "State":          "N/A",           # enriched in Step 3
                    "Private IP":     "N/A",
                    "Public IP":      "N/A",
                    "Extra Detail":   "N/A",           # type-specific field
                    "Total Vol GB":   "N/A",
                    "Created At":     event_time.strftime("%Y-%m-%d %H:%M:%S UTC"),
                    "Created By":     creator,
                    "Source IP":      source_ip,
                    "Event Name":     event_name,
                })

    print(f"\n✅ Total resource creation events: {len(rows)}")
    return rows


# ─────────────────────────────────────────────────────────────────────
# STEP 3 — Enrich rows with live AWS metadata (READ-ONLY)
# ─────────────────────────────────────────────────────────────────────
def enrich_ec2(session, rows):
    ec2    = session.client("ec2")
    ec2rows = [r for r in rows if r["Resource Type"] == "EC2 Instance"]
    if not ec2rows:
        return

    ids    = [r["Resource ID"] for r in ec2rows]
    chunks = [ids[i:i+100] for i in range(0, len(ids), 100)]
    data   = {}

    for chunk in chunks:
        try:
            resp = ec2.describe_instances(InstanceIds=chunk)
            for res in resp["Reservations"]:
                for inst in res["Instances"]:
                    iid  = inst["InstanceId"]
                    name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "N/A")
                    total_gb  = 0
                    vol_count = 0
                    for m in inst.get("BlockDeviceMappings", []):
                        vol_count += 1
                        try:
                            v = ec2.describe_volumes(VolumeIds=[m["Ebs"]["VolumeId"]])
                            total_gb += v["Volumes"][0]["Size"]
                        except Exception:
                            pass
                    data[iid] = {
                        "name":       name,
                        "state":      inst["State"]["Name"],
                        "private_ip": inst.get("PrivateIpAddress", "N/A"),
                        "public_ip":  inst.get("PublicIpAddress", "N/A"),
                        "type":       inst.get("InstanceType", "N/A"),
                        "total_gb":   total_gb,
                        "vol_count":  vol_count,
                    }
        except Exception:
            pass

    for r in ec2rows:
        d = data.get(r["Resource ID"])
        if d:
            r["Resource Name"] = d["name"]
            r["State"]         = d["state"]
            r["Private IP"]    = d["private_ip"]
            r["Public IP"]     = d["public_ip"]
            r["Extra Detail"]  = f"Type={d['type']} Volumes={d['vol_count']}"
            r["Total Vol GB"]  = d["total_gb"]


def enrich_rds(session, rows):
    rds     = session.client("rds")
    rdsrows = [r for r in rows if r["Resource Type"] == "RDS Instance"]
    if not rdsrows:
        return

    try:
        resp  = rds.describe_db_instances()
        data  = {d["DBInstanceIdentifier"]: d for d in resp["DBInstances"]}
        for r in rdsrows:
            d = data.get(r["Resource ID"])
            if d:
                r["Resource Name"] = d["DBInstanceIdentifier"]
                r["State"]         = d["DBInstanceStatus"]
                r["Private IP"]    = d.get("Endpoint", {}).get("Address", "N/A")
                r["Extra Detail"]  = f"Engine={d['Engine']} {d['EngineVersion']} Class={d['DBInstanceClass']}"
                r["Total Vol GB"]  = d.get("AllocatedStorage", "N/A")
    except Exception:
        pass


def enrich_lambda(session, rows):
    lrows = [r for r in rows if r["Resource Type"] == "Lambda Function"]
    if not lrows:
        return

    lam = session.client("lambda")
    for r in lrows:
        try:
            d = lam.get_function(FunctionName=r["Resource ID"])["Configuration"]
            r["Resource Name"] = d["FunctionName"]
            r["State"]         = d.get("State", "N/A")
            r["Extra Detail"]  = f"Runtime={d.get('Runtime','N/A')} Memory={d.get('MemorySize','N/A')}MB"
        except Exception:
            pass


def enrich_s3(session, rows):
    s3rows = [r for r in rows if r["Resource Type"] == "S3 Bucket"]
    if not s3rows:
        return

    s3 = session.client("s3")
    for r in s3rows:
        r["Resource Name"] = r["Resource ID"]
        try:
            loc = s3.get_bucket_location(Bucket=r["Resource ID"])
            r["Extra Detail"] = f"Region={loc.get('LocationConstraint','us-east-1')}"
            r["State"]        = "exists"
        except Exception:
            r["State"] = "deleted/no-access"


def enrich_volumes(session, rows):
    volrows = [r for r in rows if r["Resource Type"] == "EBS Volume"]
    if not volrows:
        return

    ec2 = session.client("ec2")
    ids = [r["Resource ID"] for r in volrows]
    try:
        resp = ec2.describe_volumes(VolumeIds=ids)
        data = {v["VolumeId"]: v for v in resp["Volumes"]}
        for r in volrows:
            d = data.get(r["Resource ID"])
            if d:
                r["State"]        = d["State"]
                r["Total Vol GB"] = d["Size"]
                r["Extra Detail"] = f"Type={d['VolumeType']} AZ={d['AvailabilityZone']}"
    except Exception:
        pass


def enrich_all(session, rows):
    print("\n🔧 Enriching with live AWS metadata ...")
    enrich_ec2(session, rows)
    enrich_rds(session, rows)
    enrich_lambda(session, rows)
    enrich_s3(session, rows)
    enrich_volumes(session, rows)
    # Other resource types have enough info from CloudTrail itself
    print("   ✅ Enrichment complete")


# ─────────────────────────────────────────────────────────────────────
# STEP 4 — Export to local CSV
# ─────────────────────────────────────────────────────────────────────
def export_csv(rows, output_file):
    if not rows:
        print("\n⚠️  No data to export.")
        return

    # Sort by created date then resource type
    rows.sort(key=lambda x: (x["Created At"], x["Resource Type"]))

    fieldnames = [
        "Resource Type", "Resource ID", "Resource Name",
        "Region", "State", "Private IP", "Public IP",
        "Extra Detail", "Total Vol GB",
        "Created At", "Created By", "Source IP", "Event Name",
    ]

    with open(output_file, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"\n{'─'*60}")
    print(f"✅  CSV saved locally: {output_file}")
    print(f"📊  Total resources  : {len(rows)}")

    # Summary by resource type
    from collections import Counter
    counts = Counter(r["Resource Type"] for r in rows)
    print(f"\n  Resource breakdown:")
    for rtype, count in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"    {rtype:<35} {count:>5}")
    print(f"{'─'*60}")


# ─────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Read-only AWS resource inventory from CloudTrail S3 logs → local CSV",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--bucket",  required=True,
                        help="S3 bucket containing CloudTrail logs")
    parser.add_argument("--account", default=None,
                        help="AWS account ID (auto-detected if not provided)")
    parser.add_argument("--prefix",  default=None,
                        help="Override full S3 prefix (skip auto-build)")
    parser.add_argument("--profile", default=None,
                        help="AWS CLI profile name")
    parser.add_argument("--region",  default="ap-southeast-2",
                        help="AWS region (default: ap-southeast-2)")
    parser.add_argument("--start",   default="2026-01-01",
                        help="Start date YYYY-MM-DD (default: 2026-01-01)")
    parser.add_argument("--end",     default=datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                        help="End date YYYY-MM-DD (default: today)")
    parser.add_argument("--output",  default=None,
                        help="Output CSV filename (default: aws_inventory_<start>_<end>.csv)")
    args = parser.parse_args()

    start_dt = datetime.strptime(args.start, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    end_dt   = datetime.strptime(args.end,   "%Y-%m-%d").replace(
                   hour=23, minute=59, second=59, tzinfo=timezone.utc)

    output_file = args.output or f"aws_inventory_{args.start}_to_{args.end}.csv"

    print("╔══════════════════════════════════════════════════════════╗")
    print("║       AWS Resource Inventory — CloudTrail S3 Parser     ║")
    print("║                    READ-ONLY MODE ✅                    ║")
    print("╚══════════════════════════════════════════════════════════╝")

    # Build boto3 session
    session    = boto3.Session(profile_name=args.profile, region_name=args.region)
    s3_client  = session.client("s3")

    # Auto-detect account ID if not provided
    if not args.account and not args.prefix:
        try:
            sts     = session.client("sts")
            account = sts.get_caller_identity()["Account"]
            print(f"\nℹ️  Auto-detected Account ID : {account}")
        except Exception as e:
            print(f"\n❌ Could not detect account ID: {e}")
            sys.exit(1)
    else:
        account = args.account

    # Build S3 prefix
    if args.prefix:
        prefix = args.prefix.rstrip("/")
    else:
        prefix = f"AWSLogs/{account}/CloudTrail/{args.region}"

    print(f"   Region       : {args.region}")
    print(f"   S3 Path      : s3://{args.bucket}/{prefix}/")
    print(f"   Date Range   : {args.start} → {args.end}")
    print(f"   Output File  : {output_file}")
    print(f"   Resources    : {len(EVENT_MAP)} event types tracked")

    # Step 1: List S3 keys
    keys = list_log_keys(s3_client, args.bucket, prefix, start_dt, end_dt)
    if not keys:
        print("\n❌ No CloudTrail log files found.")
        print("   → Check: bucket name, prefix path, date range, and s3:ListBucket permission")
        sys.exit(1)

    # Step 2: Parse logs
    rows = collect_events(s3_client, args.bucket, keys, start_dt, end_dt)
    if not rows:
        print("\n❌ No resource creation events found in the date range.")
        sys.exit(0)

    # Step 3: Enrich with live metadata
    enrich_all(session, rows)

    # Step 4: Save CSV locally
    export_csv(rows, output_file)


if __name__ == "__main__":
    main()
