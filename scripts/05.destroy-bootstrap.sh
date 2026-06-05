#!/usr/bin/env bash
###############################################################################
# scripts/05.destroy-bootstrap.sh
# Tears down everything created by 03.bootstrap.sh
#
# 1. Empties the S3 bucket (all object versions, delete markers, & fragments)
# 2. Deletes the S3 bucket
#
# ⚠️  DANGER: This permanently destroys the Terraform state file and all
#    objects in the bucket. Only run this when you're certain the
#    infrastructure managed by Terraform has already been destroyed.
###############################################################################

set -euo pipefail

BUCKET_NAME="terraform-ansible-cicd"  # Must match 03.bootstrap.sh
REGION="us-east-1"

echo "==================================================================="
echo "  Bootstrap Teardown"
echo "  Bucket : s3://$BUCKET_NAME"
echo "  Region : $REGION"
echo "==================================================================="
echo "⚠️  WARNING: This will PERMANENTLY DELETE all objects in the bucket"
echo "   including the Terraform state file."
echo ""

# ── Confirmation ────────────────────────────────────────────────────────────
read -r -p "Type the bucket name to confirm deletion [${BUCKET_NAME}]: " CONFIRM
if [ "$CONFIRM" != "$BUCKET_NAME" ]; then
  echo "❌  Confirmation failed — bucket name does not match. Aborting."
  exit 1
fi

read -r -p "Are you sure? This cannot be undone! (yes/no): " SURE
if [ "$SURE" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo ""

# ── Check bucket exists ─────────────────────────────────────────────────────
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "⏭️  Bucket '$BUCKET_NAME' does not exist — nothing to do."
  exit 0
fi

# ── Check AWS CLI ───────────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "❌  AWS CLI not found. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
  exit 1
fi

# ── Step 1: Delete all object versions, delete markers, and current versions ──
echo "🗑️  Removing all objects (including all versions and delete markers)..."

# Loop until no versions remain (handles pagination)
while true; do
  VERSION_JSON=$(aws s3api list-object-versions \
    --bucket "$BUCKET_NAME" \
    --output json \
    --max-items 200 2>/dev/null)

  VERSION_COUNT=$(echo "$VERSION_JSON" | jq '[.Versions // [] | .[]] + [.DeleteMarkers // [] | .[]] | length')

  if [ "$VERSION_COUNT" -eq 0 ]; then
    break
  fi

  echo "  Found $VERSION_COUNT version(s)/marker(s) to delete..."

  echo "$VERSION_JSON" | jq -r '
    (.Versions // [])[] | "\(.Key)|\(.VersionId)|version"
  ' 2>/dev/null | while IFS='|' read -r KEY VID TYPE; do
    aws s3api delete-object \
      --bucket "$BUCKET_NAME" \
      --key "$KEY" \
      --version-id "$VID" >/dev/null
    echo "  Deleted $TYPE: $KEY (v:$VID)"
  done

  echo "$VERSION_JSON" | jq -r '
    (.DeleteMarkers // [])[] | "\(.Key)|\(.VersionId)|delete-marker"
  ' 2>/dev/null | while IFS='|' read -r KEY VID TYPE; do
    aws s3api delete-object \
      --bucket "$BUCKET_NAME" \
      --key "$KEY" \
      --version-id "$VID" >/dev/null
    echo "  Deleted $TYPE: $KEY (v:$VID)"
  done
done

# ── Step 2: Delete any remaining objects (non-versioned) ────────────────────
echo "🗑️  Removing any remaining objects..."
aws s3 rm "s3://$BUCKET_NAME" --recursive --quiet 2>/dev/null || true

# ── Step 3: Delete multi-part upload fragments ──────────────────────────────
echo "🧹  Aborting any incomplete multipart uploads..."
UPLOADS=$(aws s3api list-multipart-uploads \
  --bucket "$BUCKET_NAME" \
  --output json \
  --query "Uploads[].{Key:Key, UploadId:UploadId}" 2>/dev/null)

if [ -n "$UPLOADS" ] && [ "$UPLOADS" != "null" ]; then
  echo "$UPLOADS" | jq -r '.[] | "\(.Key)|\(.UploadId)"' 2>/dev/null \
  | while IFS='|' read -r KEY UPLOAD_ID; do
      aws s3api abort-multipart-upload \
        --bucket "$BUCKET_NAME" \
        --key "$KEY" \
        --upload-id "$UPLOAD_ID" >/dev/null 2>&1 || true
      echo "  Aborted upload: $KEY"
    done
else
  echo "  No incomplete multipart uploads found."
fi

# ── Step 4: Delete the bucket (retry loop for eventual consistency) ─────────
echo "🗑️  Deleting bucket..."
for TRY in 1 2 3 4 5; do
  if aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
    echo "  Bucket deleted successfully."
    break
  else
    if [ "$TRY" -lt 5 ]; then
      echo "  Retrying in 3s (attempt $TRY/5)..."
      sleep 3
    else
      echo "❌  Failed to delete bucket after 5 attempts."
      echo "   It may still have objects. Check manually:"
      echo "   aws s3 ls s3://$BUCKET_NAME"
      exit 1
    fi
  fi
done

echo ""
echo "✅  Bootstrap teardown complete!"
echo "    Bucket deleted: s3://$BUCKET_NAME"
echo ""
echo "Next steps if you want to start fresh:"
echo "  1. Run ./scripts/03.bootstrap.sh  (re-creates the bucket)"
echo "  2. Run terraform init"