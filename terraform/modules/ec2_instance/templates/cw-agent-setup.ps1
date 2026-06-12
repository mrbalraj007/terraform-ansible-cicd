<powershell>
# ─── CloudWatch Agent Setup (Windows) ─────────────────────────────────────────
# Installs and starts the unified CloudWatch agent with a minimal config for
# memory (mem_used_percent), disk (disk_used_percent), and CPU metrics.
# The agent uses the attached IAM instance profile for CloudWatch auth.
# ──────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = "SilentlyContinue"
$CWAgentDir = "C:\Program Files\Amazon\AmazonCloudWatchAgent"
$CWAgentBin = "$CWAgentDir\amazon-cloudwatch-agent-ctl.ps1"
$CWAgentConfig = "$CWAgentDir\amazon-cloudwatch-agent.json"

Write-Output "=== Installing CloudWatch Agent (Windows) ==="

# Check if already installed
if (-not (Test-Path $CWAgentBin)) {
    # Download the agent installer
    $installer = "$env:TEMP\CWAgentInstaller.ps1"
    Invoke-WebRequest -Uri "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi" `
        -OutFile "$env:TEMP\amazon-cloudwatch-agent.msi" -UseBasicParsing

    # Install silently
    Start-Process msiexec.exe -ArgumentList "/i `"$env:TEMP\amazon-cloudwatch-agent.msi`" /quiet /norestart" -Wait
    Remove-Item "$env:TEMP\amazon-cloudwatch-agent.msi" -Force -ErrorAction SilentlyContinue
}

Write-Output "=== Writing CloudWatch Agent config ==="

$configJson = @'
{
    "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "cwagent",
        "logfile": "C:\\ProgramData\\Amazon\\AmazonCloudWatchAgent\\Logs\\amazon-cloudwatch-agent.log"
    },
    "metrics": {
        "metrics_collected": {
            "mem": {
                "measurement": ["mem_used_percent"],
                "metrics_collection_interval": 60
            },
            "disk": {
                "measurement": ["disk_used_percent"],
                "metrics_collection_interval": 60,
                "resources": ["C:\\"]
            },
            "swap": {
                "measurement": ["swap_used_percent"],
                "metrics_collection_interval": 60
            }
        },
        "append_dimensions": {
            "InstanceId": "${aws:InstanceId}",
            "InstanceType": "${aws:InstanceType}"
        }
    }
}
'@

# Ensure directory exists
New-Item -ItemType Directory -Force -Path "C:\ProgramData\Amazon\AmazonCloudWatchAgent" | Out-Null
Set-Content -Path "C:\ProgramData\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent.json" -Value $configJson -Force

Write-Output "=== Starting CloudWatch Agent ==="

& $CWAgentBin -a fetch-config -m ec2 -c file:"C:\ProgramData\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent.json" -s

Write-Output "=== CloudWatch Agent setup complete ==="
</powershell>