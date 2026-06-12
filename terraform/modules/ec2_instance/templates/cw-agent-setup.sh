#!/bin/bash
# ─── CloudWatch Agent Setup (Linux) ─────────────────────────────────────────
# Installs the unified CloudWatch agent and writes a minimal config that
# collects memory (mem_used_percent) and disk (disk_used_percent) metrics.
# The agent uses the attached IAM instance profile for auth to CloudWatch.
#
# This script is injected via Terraform user_data and runs at boot time.
# It only runs once — the agent persists across reboots via systemd.
# ────────────────────────────────────────────────────────────────────────────

set -e

# Detect OS family
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_FAMILY="$ID"
else
  OS_FAMILY="unknown"
fi

# ── Step 1: Install the CloudWatch Agent ───────────────────────────────────
echo "=== Installing CloudWatch Agent ==="

case "$OS_FAMILY" in
  amzn|amazonlinux)
    # Amazon Linux 2023 — use dnf
    if command -v dnf &>/dev/null; then
      dnf install -y amazon-cloudwatch-agent 2>/dev/null || \
      dnf install -y https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
    else
      yum install -y amazon-cloudwatch-agent 2>/dev/null || \
      yum install -y https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
    fi
    ;;
  ubuntu)
    apt-get update -qq
    apt-get install -y -qq amazon-cloudwatch-agent 2>/dev/null || {
      curl -sL -o /tmp/amazon-cloudwatch-agent.deb \
        https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
      dpkg -i /tmp/amazon-cloudwatch-agent.deb
      rm -f /tmp/amazon-cloudwatch-agent.deb
    }
    ;;
  rhel|centos|redhat)
    if command -v dnf &>/dev/null; then
      dnf install -y https://s3.amazonaws.com/amazoncloudwatch-agent/redhat/amd64/latest/amazon-cloudwatch-agent.rpm
    else
      yum install -y https://s3.amazonaws.com/amazoncloudwatch-agent/redhat/amd64/latest/amazon-cloudwatch-agent.rpm
    fi
    ;;
  *)
    echo "Unknown OS: $OS_FAMILY — attempting RPM install"
    rpm -Uvh https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm 2>/dev/null || true
    ;;
esac

# ── Step 2: Write the agent config ─────────────────────────────────────────
echo "=== Writing CloudWatch Agent config ==="

mkdir -p /opt/aws/amazon-cloudwatch-agent/etc

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent",
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "metrics": {
    "metrics_collected": {
      "mem": {
        "measurement": [
          "mem_used_percent"
        ],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": [
          "disk_used_percent"
        ],
        "metrics_collection_interval": 60,
        "resources": [
          "/"
        ]
      },
      "swap": {
        "measurement": [
          "swap_used_percent"
        ],
        "metrics_collection_interval": 60
      }
    },
    "append_dimensions": {
      "InstanceId": "$${aws:InstanceId}",
      "InstanceType": "$${aws:InstanceType}",
      "AutoScalingGroupName": "$${aws:AutoScalingGroupName}"
    },
    "aggregation_dimensions": [
      ["InstanceId"]
    ]
  }
}
CWCONFIG

# ── Step 3: Start the agent ────────────────────────────────────────────────
echo "=== Starting CloudWatch Agent ==="

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

echo "=== CloudWatch Agent setup complete ==="