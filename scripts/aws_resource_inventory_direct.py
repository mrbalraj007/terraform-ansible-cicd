#!/usr/bin/env python3
"""
aws_resource_inventory_direct.py
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
READ-ONLY — No S3 bucket required. No Athena required.

Data sources (auto-selected based on date range):
  ① CloudTrail lookup_events API  → last 90 days  (always available)
  ② CloudWatch Logs Insights      → older events   (if CT→CW Logs enabled)

The script automatically:
  • Uses source ① for the recent 90-day window
  • Uses source ② for anything older (e.g. Jan 2026)
  • Merges both, deduplicates, enriches with live AWS metadata
  • Saves a single CSV file locally

Supported resource types (20):
  EC2, S3, RDS, Lambda, IAM User, IAM Role, Security Group,
  VPC, Subnet, EBS Volume, EKS Cluster, CloudFormation Stack,
  DynamoDB Table, SNS Topic, SQS Queue, Load Balancer,
  Auto Scaling Group, ECR Repository, KMS Key, Secrets Manager Secret

Usage:
  # Minimal (uses both sources automatically)
  python3 aws_resource_inventory_direct.py

  # With options
  python3 aws_resource_inventory_direct.py \
    --profile  my-profile \
    --region   ap-southeast-2 \
    --start    2026-01-01 \
    --end      2026-06-11 \
    --log-group /aws/cloudtrail \
    --output   aws_inventory.csv

IAM permissions required (READ-ONLY):
  cloudtrail:LookupEvents
  logs:StartQuery, logs:GetQueryResults, logs:DescribeLogGroups
  ec2:DescribeInstances, ec2:DescribeVolumes, ec2:DescribeSecurityGroups
  ec2:DescribeVpcs, ec2:DescribeSubnets
  rds:DescribeDBInstances
  lambda:GetFunction
  sts:GetCallerIdentity
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"""

import boto3
import csv
import json
import argparse
import time
import sys
from datetime import datetime, timezone, timedelta
from collections import Counter
from botocore.exceptions import ClientError

# ─────────────────────────────────────────────────────────────────────
# EVENT MAP — CloudTrail eventName → resource type label
# ─────────────────────────────────────────────────────────────────────
EVENT_MAP = {
    "RunInstances":             "EC2 Instance",
    "CreateBucket":             "S3 Bucket",
    "CreateDBInstance":         "RDS Instance",
    "CreateFunction20150331":   "Lambda Function",
    "CreateFunction":           "Lambda Function",
    "CreateUser":               "IAM User",
    "CreateRole":               "IAM Role",
    "CreateSecurityGroup":      "Security Group",
    "CreateVpc":                "VPC",
    "CreateSubnet":             "Subnet",
    "CreateVolume":             "EBS Volume",
    "CreateCluster":            "EKS Cluster",
    "CreateStack":              "CloudFormation Stack",
    "CreateTable":              "DynamoDB Table",
    "CreateTopic":              "SNS Topic",
    "CreateQueue":              "SQS Queue",
    "CreateLoadBalancer":       "Load Balancer",
    "CreateAutoScalingGroup":   "Auto Scaling Group",
    "CreateRepository":         "ECR Repository",
    "CreateKey":                "KMS Key",
    "CreateSecret":             "Secrets Manager Secret",
}

CLOUDTRAIL_MAX_DAYS = 90   # Hard limit of lookup_events API


# ─────────────────────────────────────────────────────────────────────
# HELPER — Parse a raw CloudTrail record into a flat resource row
# ─────────────────────────────────────────────────────────────────────
def parse_event_record(record):
    """
    Given a CloudTrail record dict, return list of resource rows.
    One RunInstances call can create multiple EC2s → multiple rows.
    Returns [] if the event should be skipped (error, unknown type).
    """
    event_name = record.get("eventName", "")
    if event_name not in EVENT_MAP:
        return []

    # Skip failed API calls
    if record.get("errorCode"):
        return []

    resource_type = EVENT_MAP[event_name]
    aws_region    = record.get("awsRegion", "N/A")
    source_ip     = record.get("sourceIPAddress", "N/A")

    uid     = record.get("userIdentity", {})
    creator = (
        uid.get("arn") or
        uid.get("userName") or
        uid.get("principalId") or
        uid.get("type", "unknown")
    )

    event_time_raw = record.get("eventTime", "")
    try:
        event_time = datetime.strptime(
            event_time_raw, "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=timezone.utc)
        created_at = event_time.strftime("%Y-%m-%d %H:%M:%S UTC")
    except ValueError:
        created_at = event_time_raw

    resp = record.get("responseElements") or {}
    req  = record.get("requestParameters") or {}

    resource_ids = _extract_ids(event_name, resp, req)

    rows = []
    for rid in resource_ids:
        if not rid or rid in ("N/A", ""):
            continue
        rows.append({
            "Resource Type": resource_type,
            "Resource ID":   rid,
            "Resource Name": "N/A",
            "Region":        aws_region,
            "State":         "N/A",
            "Private IP":    "N/A",
            "Public IP":     "N/A",
            "Extra Detail":  "N/A",
            "Total Vol GB":  "N/A",
            "Created At":    created_at,
            "Created By":    creator,
            "Source IP":     source_ip,
            "Event Name":    event_name,
            "Data Source":   "N/A",   # filled by caller
        })
    return rows


def _extract_ids(name, resp, req):
    """Extract resource identifier(s) from a CloudTrail event."""
    if name == "RunInstances":
        items = resp.get("instancesSet", {}).get("items", [])
        return [i.get("instanceId", "") for i in items]

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
        return [lb.get("loadBalancerName", lb.get("loadBalancerArn", "N/A")) for lb in lbs] or ["N/A"]

    if name == "CreateAutoScalingGroup":
        return [req.get("autoScalingGroupName", "N/A")]

    if name == "CreateRepository":
        return [resp.get("repository", {}).get("repositoryName", req.get("repositoryName", "N/A"))]

    if name == "CreateKey":
        return [resp.get("keyMetadata", {}).get("keyId", "N/A")]

    if name == "CreateSecret":
        return [resp.get("name", req.get("name", "N/A"))]

    return ["N/A"]


# ─────────────────────────────────────────────────────────────────────
# SOURCE ① — CloudTrail lookup_events API (last 90 days)
# ─────────────────────────────────────────────────────────────────────
def fetch_from_cloudtrail_api(ct_client, start_dt, end_dt):
    """
    Uses CloudTrail LookupEvents API — no S3, no CW Logs needed.
    Limited to last 90 days by AWS.
    Queries each event type separately to maximise results returned.
    """
    rows = []
    now  = datetime.now(timezone.utc)

    # Clamp to 90-day window
    api_start = max(start_dt, now - timedelta(days=89))
    api_end   = min(end_dt, now)

    if api_start >= api_end:
        return rows

    print(f"\n{'─'*60}")
    print(f"  SOURCE ①  CloudTrail lookup_events API")
    print(f"  Window  : {api_start.date()} → {api_end.date()}")
    print(f"{'─'*60}")

    for event_name in EVENT_MAP:
        try:
            paginator = ct_client.get_paginator("lookup_events")
            pages     = paginator.paginate(
                LookupAttributes=[
                    {"AttributeKey": "EventName", "AttributeValue": event_name}
                ],
                StartTime=api_start,
                EndTime=api_end,
            )
            count = 0
            for page in pages:
                for event in page.get("Events", []):
                    # CloudTrail lookup_events wraps the record in CloudTrailEvent (JSON string)
                    raw = event.get("CloudTrailEvent")
                    if raw:
                        try:
                            record = json.loads(raw)
                        except Exception:
                            continue
                    else:
                        # Fallback: build minimal record from top-level fields
                        record = {
                            "eventName":      event.get("EventName", ""),
                            "eventTime":      event.get("EventTime", datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
                                              if isinstance(event.get("EventTime"), datetime)
                                              else str(event.get("EventTime", "")),
                            "awsRegion":      "N/A",
                            "sourceIPAddress": "N/A",
                            "userIdentity":   {},
                            "responseElements": {},
                            "requestParameters": {},
                        }

                    parsed = parse_event_record(record)
                    for r in parsed:
                        r["Data Source"] = "CloudTrail API"
                    rows.extend(parsed)
                    count += len(parsed)

            if count:
                print(f"  ✅  {event_name:<40} {count} resource(s)")

        except ClientError as e:
            code = e.response["Error"]["Code"]
            print(f"  ⚠️  {event_name:<40} Skipped ({code})")
        except Exception as e:
            print(f"  ⚠️  {event_name:<40} Error: {e}")

    print(f"\n  Subtotal from CloudTrail API : {len(rows)} events")
    return rows


# ─────────────────────────────────────────────────────────────────────
# SOURCE ② — CloudWatch Logs Insights (for events older than 90 days)
# ─────────────────────────────────────────────────────────────────────
def find_cloudtrail_log_group(cw_client, hint=None):
    """
    Auto-discover the CloudTrail log group if not specified.
    Common names: /aws/cloudtrail, CloudTrail/DefaultLogGroup, etc.
    """
    if hint:
        return hint

    common_prefixes = ["/aws/cloudtrail", "CloudTrail", "cloudtrail", "aws-cloudtrail"]
    paginator = cw_client.get_paginator("describe_log_groups")

    for page in paginator.paginate():
        for lg in page.get("logGroups", []):
            name = lg["logGroupName"]
            for prefix in common_prefixes:
                if prefix.lower() in name.lower():
                    print(f"  ℹ️  Auto-detected log group: {name}")
                    return name
    return None


def fetch_from_cloudwatch_insights(cw_client, log_group, start_dt, end_dt, event_names):
    """
    Query CloudWatch Logs Insights for CloudTrail events older than 90 days.
    Runs one query per batch of event names.
    """
    rows = []

    print(f"\n{'─'*60}")
    print(f"  SOURCE ②  CloudWatch Logs Insights")
    print(f"  Log Group : {log_group}")
    print(f"  Window    : {start_dt.date()} → {end_dt.date()}")
    print(f"{'─'*60}")

    # Build filter string for all event names
    event_filter = " or ".join([f'eventName = "{e}"' for e in event_names])

    query = f"""
fields @timestamp, @message
| filter ({event_filter})
| filter ispresent(responseElements)
| sort @timestamp asc
| limit 10000
"""

    try:
        resp     = cw_client.start_query(
            logGroupName=log_group,
            startTime=int(start_dt.timestamp()),
            endTime=int(end_dt.timestamp()),
            queryString=query,
        )
        query_id = resp["queryId"]

        # Poll until complete
        print("  ⏳ Running query", end="", flush=True)
        while True:
            result = cw_client.get_query_results(queryId=query_id)
            status = result["status"]
            if status == "Complete":
                print(f" ✅  ({len(result['results'])} raw results)")
                break
            elif status in ("Failed", "Cancelled", "Timeout"):
                print(f"\n  ❌ Query {status}")
                return rows
            print(".", end="", flush=True)
            time.sleep(3)

        # Parse each result row
        for row in result["results"]:
            row_dict = {r["field"]: r["value"] for r in row}
            raw_msg  = row_dict.get("@message", "")
            try:
                record = json.loads(raw_msg)
            except Exception:
                continue

            parsed = parse_event_record(record)
            for r in parsed:
                r["Data Source"] = "CloudWatch Logs Insights"
            rows.extend(parsed)

    except ClientError as e:
        print(f"\n  ⚠️  CloudWatch Logs Insights error: {e.response['Error']['Message']}")

    print(f"  Subtotal from CloudWatch Insights : {len(rows)} events")
    return rows


# ─────────────────────────────────────────────────────────────────────
# STEP 3 — Enrich with live AWS metadata (READ-ONLY)
# ─────────────────────────────────────────────────────────────────────
def enrich_ec2(session, rows):
    ec2rows = [r for r in rows if r["Resource Type"] == "EC2 Instance"]
    if not ec2rows:
        return
    ec2    = session.client("ec2")
    ids    = [r["Resource ID"] for r in ec2rows]
    chunks = [ids[i:i+100] for i in range(0, len(ids), 100)]
    data   = {}

    for chunk in chunks:
        try:
            resp = ec2.describe_instances(InstanceIds=chunk)
            for res in resp["Reservations"]:
                for inst in res["Instances"]:
                    iid      = inst["InstanceId"]
                    name     = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "N/A")
                    total_gb = 0
                    vol_cnt  = 0
                    for m in inst.get("BlockDeviceMappings", []):
                        vol_cnt += 1
                        try:
                            v = ec2.describe_volumes(VolumeIds=[m["Ebs"]["VolumeId"]])
                            total_gb += v["Volumes"][0]["Size"]
                        except Exception:
                            pass
                    data[iid] = {
                        "name":      name,
                        "state":     inst["State"]["Name"],
                        "priv_ip":   inst.get("PrivateIpAddress", "N/A"),
                        "pub_ip":    inst.get("PublicIpAddress",  "N/A"),
                        "itype":     inst.get("InstanceType",     "N/A"),
                        "total_gb":  total_gb,
                        "vol_cnt":   vol_cnt,
                    }
        except Exception:
            pass

    for r in ec2rows:
        d = data.get(r["Resource ID"])
        if d:
            r["Resource Name"] = d["name"]
            r["State"]         = d["state"]
            r["Private IP"]    = d["priv_ip"]
            r["Public IP"]     = d["pub_ip"]
            r["Extra Detail"]  = f"Type={d['itype']} Volumes={d['vol_cnt']}"
            r["Total Vol GB"]  = d["total_gb"]


def enrich_rds(session, rows):
    rds_rows = [r for r in rows if r["Resource Type"] == "RDS Instance"]
    if not rds_rows:
        return
    rds = session.client("rds")
    try:
        resp = rds.describe_db_instances()
        data = {d["DBInstanceIdentifier"]: d for d in resp["DBInstances"]}
        for r in rds_rows:
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
    print(f"\n{'─'*60}")
    print("  🔧 Enriching with live AWS metadata ...")
    enrich_ec2(session, rows)
    enrich_rds(session, rows)
    enrich_lambda(session, rows)
    enrich_s3(session, rows)
    enrich_volumes(session, rows)
    print("  ✅ Enrichment complete")


# ─────────────────────────────────────────────────────────────────────
# STEP 4 — Deduplicate + Export CSV locally
# ─────────────────────────────────────────────────────────────────────
def deduplicate(rows):
    seen    = {}
    deduped = []
    for r in rows:
        key = f"{r['Resource ID']}_{r['Created At']}"
        if key not in seen:
            seen[key] = True
            deduped.append(r)
    return deduped


def export_csv(rows, output_file):
    if not rows:
        print("\n⚠️  No data to export.")
        return

    rows.sort(key=lambda x: (x["Created At"], x["Resource Type"]))

    fieldnames = [
        "Resource Type", "Resource ID", "Resource Name",
        "Region", "State", "Private IP", "Public IP",
        "Extra Detail", "Total Vol GB",
        "Created At", "Created By", "Source IP",
        "Event Name", "Data Source",
    ]

    with open(output_file, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"\n{'═'*60}")
    print(f"  ✅  CSV saved : {output_file}")
    print(f"  📊  Total     : {len(rows)} resources")
    counts = Counter(r["Resource Type"] for r in rows)
    print(f"\n  Breakdown by resource type:")
    for rtype, cnt in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"    {rtype:<38} {cnt:>5}")
    print(f"{'═'*60}")


# ─────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Read-only AWS resource inventory (no S3, no Athena) → local CSV",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--profile",   default=None,
                        help="AWS CLI profile name")
    parser.add_argument("--region",    default="ap-southeast-2",
                        help="AWS region (default: ap-southeast-2)")
    parser.add_argument("--start",     default="2026-01-01",
                        help="Start date YYYY-MM-DD (default: 2026-01-01)")
    parser.add_argument("--end",       default=datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                        help="End date YYYY-MM-DD (default: today)")
    parser.add_argument("--log-group", default=None,
                        help="CloudWatch log group for CloudTrail (auto-detected if not set)")
    parser.add_argument("--output",    default=None,
                        help="Output CSV filename (default: aws_inventory_<start>_<end>.csv)")
    args = parser.parse_args()

    start_dt    = datetime.strptime(args.start, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    end_dt      = datetime.strptime(args.end,   "%Y-%m-%d").replace(
                      hour=23, minute=59, second=59, tzinfo=timezone.utc)
    output_file = args.output or f"aws_inventory_{args.start}_to_{args.end}.csv"
    now         = datetime.now(timezone.utc)
    cutoff_90d  = now - timedelta(days=90)

    print("╔══════════════════════════════════════════════════════════╗")
    print("║     AWS Resource Inventory — No S3 / No Athena          ║")
    print("║                  READ-ONLY MODE ✅                      ║")
    print("╚══════════════════════════════════════════════════════════╝")
    print(f"  Profile   : {args.profile or 'default'}")
    print(f"  Region    : {args.region}")
    print(f"  Date Range: {args.start} → {args.end}")
    print(f"  Output    : {output_file}")

    session    = boto3.Session(profile_name=args.profile, region_name=args.region)
    ct_client  = session.client("cloudtrail")
    cw_client  = session.client("logs")

    all_rows = []

    # ── SOURCE ① CloudTrail API (last 90 days window only) ──────────
    api_end   = min(end_dt,   now)
    api_start = max(start_dt, cutoff_90d)

    if api_start < api_end:
        rows_api = fetch_from_cloudtrail_api(ct_client, api_start, api_end)
        all_rows.extend(rows_api)

    # ── SOURCE ② CloudWatch Logs Insights (for dates older than 90d) ─
    if start_dt < cutoff_90d:
        cw_end   = min(end_dt,      cutoff_90d)
        cw_start = start_dt

        log_group = find_cloudtrail_log_group(cw_client, args.log_group)

        if log_group:
            rows_cw = fetch_from_cloudwatch_insights(
                cw_client, log_group, cw_start, cw_end, list(EVENT_MAP.keys())
            )
            all_rows.extend(rows_cw)
        else:
            print("\n  ⚠️  No CloudTrail log group found in CloudWatch Logs.")
            print("      Events before 90 days ago will not be included.")
            print("      → Tip: Pass --log-group <name> if your group has a custom name.")
    else:
        print(f"\n  ℹ️  Date range is within 90 days — CloudTrail API is sufficient.")

    if not all_rows:
        print("\n❌ No resource creation events found. Check your date range and permissions.")
        sys.exit(0)

    # ── Deduplicate (overlap between sources) ───────────────────────
    before = len(all_rows)
    all_rows = deduplicate(all_rows)
    dupes    = before - len(all_rows)
    if dupes:
        print(f"\n  🔁 Removed {dupes} duplicate event(s) from source overlap")

    # ── Enrich with live metadata ────────────────────────────────────
    enrich_all(session, all_rows)

    # ── Export locally ───────────────────────────────────────────────
    export_csv(all_rows, output_file)


if __name__ == "__main__":
    main()