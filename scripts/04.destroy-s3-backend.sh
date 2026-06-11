#!/usr/bin/env bash
###############################################################################
# scripts/05.destroy-s3-backend.sh
# Tears down the S3 bucket created by 03.setup_s3-backend.sh
#
# 1. Lists all matching buckets (by repo naming pattern)
# 2. Lets user pick one (or enter manually)
# 3. Checks Object Lock status and warns if enabled
# 4. Empties the bucket (all versions, delete markers, fragments)
# 5. Deletes the S3 bucket
#
# ⚠️  DANGER: This permanently destroys the Terraform state. Only run this
#    when infrastructure managed by Terraform has already been destroyed.
###############################################################################

set -euo pipefail

REGION="us-east-1"
TODAY=$(date +%Y%m%d)

# Detect repo details
if command -v gh &>/dev/null && gh auth status &>/dev/null; then
  GITHUB_FULL_NAME=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')
  GITHUB_ORG=$(echo "$GITHUB_FULL_NAME" | cut -d/ -f1)
  GITHUB_REPO=$(echo "$GITHUB_FULL_NAME" | cut -d/ -f2)
else
  GITHUB_ORG="mrbalraj007"
  GITHUB_REPO="aws-oidc-terraform-ansible-cicd"
fi

BUCKET_PREFIX="${GITHUB_REPO}-"

echo "==================================================================="
echo "  S3 Backend Teardown"
echo "  Org/Repo : $GITHUB_ORG/$GITHUB_REPO"
echo "  Region   : $REGION"
echo "==================================================================="
echo ""

# ── Check AWS CLI ───────────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "❌  AWS CLI not found. Install it first."
  exit 1
fi

# ── List buckets matching the project naming pattern ────────────────────────
echo "🔍  Scanning for buckets matching '${BUCKET_PREFIX}*'..."
MATCHING_BUCKETS=()
while IFS= read -r bucket; do
  MATCHING_BUCKETS+=("$bucket")
done < <(aws s3api list-buckets --output json 2>/dev/null | jq -r \
  --arg prefix "$BUCKET_PREFIX" \
  '.Buckets[] | select(.Name | startswith($prefix)) | .Name' | sort)

echo ""
if [ ${#MATCHING_BUCKETS[@]} -eq 0 ]; then
  echo "ℹ️   No buckets found matching '${BUCKET_PREFIX}*'."
  echo "    Enter the bucket name manually (or press Ctrl+C to abort):"
  read -r -p "Bucket name: " BUCKET_NAME
else
  echo "📋  Found ${#MATCHING_BUCKETS[@]} bucket(s):"
  echo ""
  for i in "${!MATCHING_BUCKETS[@]}"; do
    CREATED=$(aws s3api list-buckets --output json 2>/dev/null | jq -r \
      --arg name "${MATCHING_BUCKETS[$i]}" \
      '.Buckets[] | select(.Name == $name) | .CreationDate | split("T")[0]')
    echo "  [$((i+1))] ${MATCHING_BUCKETS[$i]}  (created: $CREATED)"
  done
  echo ""
  echo "  [0]  Enter bucket name manually"
  echo ""

  read -r -p "Select a bucket to delete [1]: " CHOICE

  if [ -z "$CHOICE" ] || [ "$CHOICE" = "1" ]; then
    if [ ${#MATCHING_BUCKETS[@]} -eq 1 ]; then
      BUCKET_NAME="${MATCHING_BUCKETS[0]}"
    else
      echo "❌  Please select a number between 1 and ${#MATCHING_BUCKETS[@]}"
      exit 1
    fi
  elif [ "$CHOICE" = "0" ]; then
    read -r -p "Bucket name: " BUCKET_NAME
  else
    IDX=$((CHOICE - 1))
    if [ "$IDX" -ge 0 ] && [ "$IDX" -lt ${#MATCHING_BUCKETS[@]} ]; then
      BUCKET_NAME="${MATCHING_BUCKETS[$IDX]}"
    else
      echo "❌  Invalid selection."
      exit 1
    fi
  fi
fi

if [ -z "$BUCKET_NAME" ]; then
  echo "❌  No bucket name provided. Aborting."
  exit 1
fi

echo ""
echo "==================================================================="
echo "  Target : s3://$BUCKET_NAME"
echo "==================================================================="
echo "⚠️  WARNING: This will PERMANENTLY DELETE all objects in the bucket"
echo "   including the Terraform state file."
echo ""

# ── Check bucket exists ─────────────────────────────────────────────────────
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "❌  Bucket '$BUCKET_NAME' does not exist. Aborting."
  exit 1
fi

# ── Check if Object Lock is enabled ─────────────────────────────────────────
echo "🔒  Checking Object Lock configuration..."
OBJECT_LOCK_CONFIG=$(aws s3api get-object-lock-configuration \
  --bucket "$BUCKET_NAME" \
  --output json 2>/dev/null || echo "{}")

OBJECT_LOCK_ENABLED=$(echo "$OBJECT_LOCK_CONFIG" | jq -r '.ObjectLockConfiguration.ObjectLockEnabled // "Disabled"')
echo "   Object Lock: $OBJECT_LOCK_ENABLED"

# Determine if we need to bypass governance retention
BYPASS_FLAG=""
if [ "$OBJECT_LOCK_ENABLED" = "Enabled" ]; then
  echo "⚠️  Object Lock is ENABLED — will use --bypass-governance-retention"
  BYPASS_FLAG="--bypass-governance-retention"
fi

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

# ── Step 1: Delete all object versions and delete markers ───────────────────
echo "🗑️  Removing all object versions and delete markers..."

while true; do
  # List with pagination - get up to 1000 items at a time
  VERSION_JSON=$(aws s3api list-object-versions \
    --bucket "$BUCKET_NAME" \
    --output json \
    --max-items 1000 2>/dev/null)

  # Capture NextToken for pagination
  NEXT_TOKEN=$(echo "$VERSION_JSON" | jq -r '.NextToken // empty')

  VERSION_COUNT=$(echo "$VERSION_JSON" | jq '[.Versions // [] | .[]] + [.DeleteMarkers // [] | .[]] | length' 2>/dev/null)

  if [ "$VERSION_COUNT" -eq 0 ] || [ -z "$VERSION_COUNT" ]; then
    # No more versions - check if there are more pages
    if [ -z "$NEXT_TOKEN" ]; then
      break
    fi
    # Continue to fetch next page
    echo "  Fetching next page..."
    continue
  fi

  echo "  Found $VERSION_COUNT version(s)/marker(s) in this page..."

  # Build delete payload for all versions in this page
  VERSIONS_ARR=$(echo "$VERSION_JSON" | jq '[.Versions[] | {Key: .Key, VersionId: .VersionId}]')
  if [ "$(echo "$VERSIONS_ARR" | jq 'length')" -gt 0 ]; then
    DELETE_PAYLOAD=$(echo "$VERSIONS_ARR" | jq -c '{Objects: .}')
    RESULT=$(aws s3api delete-objects \
      --bucket "$BUCKET_NAME" \
      --delete "$DELETE_PAYLOAD" \
      $BYPASS_FLAG \
      --output json 2>&1) || true
    if echo "$RESULT" | jq -e '.Deleted' >/dev/null 2>&1; then
      echo "$RESULT" | jq -r '.Deleted[] | "  Deleted: \(.Key) (v:\(.VersionId))"' || true
    fi
    if echo "$RESULT" | jq -e '.Error' >/dev/null 2>&1; then
      echo "$RESULT" | jq -r '.Error[] | "  ERROR: \(.Key) - \(.Message)"' || true
    fi
  fi

  # Build delete payload for all delete markers in this page
  DMS_ARR=$(echo "$VERSION_JSON" | jq '[(.DeleteMarkers // [])[] | {Key: .Key, VersionId: .VersionId}]')
  if [ "$(echo "$DMS_ARR" | jq 'length')" -gt 0 ]; then
    DELETE_PAYLOAD=$(echo "$DMS_ARR" | jq -c '{Objects: .}')
    RESULT=$(aws s3api delete-objects \
      --bucket "$BUCKET_NAME" \
      --delete "$DELETE_PAYLOAD" \
      $BYPASS_FLAG \
      --output json 2>&1) || true
    if echo "$RESULT" | jq -e '.Deleted' >/dev/null 2>&1; then
      echo "$RESULT" | jq -r '.Deleted[] | "  Deleted marker: \(.Key) (v:\(.VersionId))"' || true
    fi
    if echo "$RESULT" | jq -e '.Error' >/dev/null 2>&1; then
      echo "$RESULT" | jq -r '.Error[] | "  ERROR: \(.Key) - \(.Message)"' || true
    fi
  fi

  # If there's a NextToken, continue to next page without re-listing
  if [ -n "$NEXT_TOKEN" ] && [ "$NEXT_TOKEN" != "null" ]; then
    echo "  More versions exist, fetching next page..."
    # Use starting-token for pagination
    VERSION_JSON=$(aws s3api list-object-versions \
      --bucket "$BUCKET_NAME" \
      --output json \
      --max-items 1000 \
      --starting-token "$NEXT_TOKEN" 2>/dev/null)
    continue
  else
    break
  fi
done

# ── Step 2: Delete any remaining objects (non-versioned) ────────────────────
echo "🗑️  Removing any remaining objects..."
if [ -n "$BYPASS_FLAG" ]; then
  aws s3 rm "s3://$BUCKET_NAME" --recursive $BYPASS_FLAG 2>&1 || true
else
  aws s3 rm "s3://$BUCKET_NAME" --recursive 2>&1 || true
fi

# ── Step 3: Abort incomplete multipart uploads ──────────────────────────────
echo "🧹  Aborting incomplete multipart uploads..."
UPLOADS=$(aws s3api list-multipart-uploads \
  --bucket "$BUCKET_NAME" \
  --output json \
  --query "Uploads[].{Key:Key, UploadId:UploadId}" 2>/dev/null)

if [ -n "$UPLOADS" ] && [ "$UPLOADS" != "null" ]; then
  echo "$UPLOADS" | jq -r '.[] | "\(.Key)|\(.UploadId)"' 2>/dev/null | \
    while IFS='|' read -r KEY UPLOAD_ID; do
      aws s3api abort-multipart-upload \
        --bucket "$BUCKET_NAME" --key "$KEY" --upload-id "$UPLOAD_ID" >/dev/null 2>&1 || true
      echo "  Aborted upload: $KEY"
    done
else
  echo "  No incomplete multipart uploads found."
fi

# ── Verify bucket is empty ───────────────────────────────────────────────────
echo ""
echo "🔍  Verifying bucket is empty..."
REMAINING=$(aws s3api list-objects --bucket "$BUCKET_NAME" --output json 2>/dev/null | jq '.Contents | length' 2>/dev/null || echo "0")
REMAINING_VERSIONS=$(aws s3api list-object-versions --bucket "$BUCKET_NAME" --output json 2>/dev/null | jq '[.Versions // [], .DeleteMarkers // []] | flatten | length' 2>/dev/null || echo "0")

if [ "$REMAINING" -gt 0 ] || [ "$REMAINING_VERSIONS" -gt 0 ]; then
  echo "⚠️  Warning: Bucket may still have objects (Objects: $REMAINING, Versions: $REMAINING_VERSIONS)"
  echo "   Will still attempt bucket deletion..."
fi

# ── Step 4: Delete the bucket ───────────────────────────────────────────────
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
      echo "   aws s3api list-object-versions --bucket $BUCKET_NAME"
      exit 1
    fi
  fi
done

echo ""
echo "✅  Teardown complete! Bucket deleted: s3://$BUCKET_NAME"
echo ""
echo "Next steps to start fresh:"
echo "  1. ./scripts/03.setup_s3-backend.sh  (re-creates bucket + backend.tf)"
echo "  2. cd terraform && terraform init"