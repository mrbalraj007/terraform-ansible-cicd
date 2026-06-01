#!/usr/bin/env bash
###############################################################################
# scripts/bootstrap.sh
# Run ONCE locally before `terraform init`
# Creates the S3 bucket used to store Terraform remote state
###############################################################################

set -euo pipefail

BUCKET_NAME="terraform-ansible-cicd"  # <-- Change this to a unique bucket name (must be globally unique)
REGION="us-east-1"

echo "==================================================================="
echo "  terraform-ansible-cicd — State Bucket Bootstrap"
echo "  Bucket : $BUCKET_NAME"
echo "  Region : $REGION"
echo "==================================================================="

# ── Check AWS CLI is available ────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "❌  AWS CLI not found. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
  exit 1
fi

# ── Check bucket already exists ──────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "✅  Bucket '$BUCKET_NAME' already exists — nothing to do."
  exit 0
fi

echo "📦  Creating S3 bucket..."
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION"
else
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi

echo "🔒  Enabling versioning..."
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

echo "🔐  Enabling server-side encryption..."
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

echo "🚫  Blocking public access..."
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo ""
echo "✅  Bootstrap complete!"
echo "    Bucket : s3://$BUCKET_NAME"
echo ""
echo "Next step → run: terraform init"