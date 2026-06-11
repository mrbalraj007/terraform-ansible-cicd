#!/usr/bin/env bash
###############################################################################
# scripts/03.bootstrap.sh
# Run ONCE locally before `terraform init`
# Creates the S3 bucket used to store Terraform remote state.
# Features: Object Lock (WORM), dynamic bucket naming, auto-backend config.
###############################################################################

set -euo pipefail

# ---- CONFIGURATION ----
AWS_REGION="us-east-1"
TODAY=$(date +%Y%m%d)

# Dynamic bucket naming: <github-repo>-<date>
# Detect repo owner and name dynamically via gh CLI
if command -v gh &>/dev/null && gh auth status &>/dev/null; then
  GITHUB_FULL_NAME=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')
  GITHUB_ORG=$(echo "$GITHUB_FULL_NAME" | cut -d/ -f1)
  GITHUB_REPO=$(echo "$GITHUB_FULL_NAME" | cut -d/ -f2)
else
  GITHUB_ORG="mrbalraj007"
  GITHUB_REPO="aws-oidc-terraform-ansible-cicd"
fi
BUCKET_NAME="${GITHUB_REPO}-${TODAY}"

echo "==================================================================="
echo "  terraform-ansible-cicd — State Bucket Bootstrap"
echo "  Account : $(aws sts get-caller-identity --query Account --output text)"
echo "  Bucket  : $BUCKET_NAME"
echo "  Region  : $AWS_REGION"
echo "==================================================================="

# ── Check AWS CLI is available ────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "❌  AWS CLI not found. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
  exit 1
fi

# ── Write Terraform backend config (always update, even if bucket already exists) ─
echo ""
echo "📝  Updating Terraform backend config..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_BACKEND_FILE="$SCRIPT_DIR/../terraform/backend.tf"
mkdir -p "$(dirname "$TF_BACKEND_FILE")"
cat > "$TF_BACKEND_FILE" <<EOF
terraform {
  backend "s3" {
    bucket         = "$BUCKET_NAME"
    key            = "terraform.tfstate"
    region         = "$AWS_REGION"
    encrypt        = true
    use_lockfile   = true
  }
}
EOF
echo "   Updated $TF_BACKEND_FILE"

# ── Check bucket already exists ──────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "✅  Bucket '$BUCKET_NAME' already exists — backend.tf updated."
  exit 0
fi

# ── Create S3 Bucket ─────────────────────────────────────────────────────────
echo ""
echo "📦  Creating S3 bucket..."
if [ "$AWS_REGION" = "us-east-1" ]; then
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$AWS_REGION" || true
else
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" || true
fi

# ── Enable versioning (required for Object Lock) ─────────────────────────────
echo "🔒  Enabling versioning..."
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

# ── Enable Object Lock (WORM protection) ─────────────────────────────────────
echo "🔐  Enabling Object Lock (GOVERNANCE, 7 days)..."
aws s3api put-object-lock-configuration \
  --bucket "$BUCKET_NAME" \
  --object-lock-configuration '{"ObjectLockEnabled": "Enabled", "Rule": {"DefaultRetention": {"Mode": "GOVERNANCE", "Days": 7}}}'

# ── Enable server-side encryption ────────────────────────────────────────────
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

# ── Block public access ───────────────────────────────────────────────────────
echo "🚫  Blocking public access..."
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# ── Add TF_VAR_tf_state_bucket secret to GitHub Actions ──────────────────────
echo ""
if command -v gh &>/dev/null && gh auth status &>/dev/null; then
  echo "🔑  Adding TF_VAR_tf_state_bucket secret to GitHub Actions..."
  if gh secret set TF_VAR_tf_state_bucket --body "$BUCKET_NAME" \
       --repo "$GITHUB_ORG/$GITHUB_REPO"; then
    echo "   ✅  Secret set: TF_VAR_tf_state_bucket = $BUCKET_NAME"
  else
    echo "   ❌  Failed to set secret. Run manually:"
    echo "       gh secret set TF_VAR_tf_state_bucket --body '$BUCKET_NAME'"
  fi
else
  echo "ℹ️   GitHub CLI not available or not authenticated."
  echo "    Set the secret manually:"
  echo "    gh secret set TF_VAR_tf_state_bucket --body '$BUCKET_NAME'"
fi

echo ""
echo "==================================================================="
echo "✅  Bootstrap complete!"
echo "    Bucket   : s3://$BUCKET_NAME"
echo "    Backend  : $TF_BACKEND_FILE"
echo "    Secret   : TF_VAR_tf_state_bucket = $BUCKET_NAME"
echo "    Note     : Uses S3 native lockfile (no DynamoDB)"
echo ""
echo "Next step → run: cd terraform && terraform init"
echo "==================================================================="