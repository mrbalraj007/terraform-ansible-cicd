#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# setup-aws-oidc.sh
# Creates the IAM Role + OIDC provider for GitHub Actions
# ──────────────────────────────────────────────────────────────
set -euo pipefail

GITHUB_ORG="mrbalraj007"
GITHUB_REPO="terraform-ansible-cicd"
AWS_REGION="us-east-1"
ROLE_NAME="github-actions-terraform-role"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Account: $ACCOUNT_ID"
echo "Creating OIDC provider..."

aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  2>/dev/null || echo "OIDC provider already exists"

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
      },
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "IAM role '$ROLE_NAME' already exists — updating trust policy..."
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
else
  echo "Creating IAM role..."
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY"
fi

# Attach policies (idempotent — skips if already attached)
echo "Attaching policies..."
for POLICY_ARN in \
  arn:aws:iam::aws:policy/AmazonEC2FullAccess \
  arn:aws:iam::aws:policy/AmazonS3FullAccess \
  arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess; do
  if ! aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyArn" --output text | grep -q "$POLICY_ARN"; then
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
    echo "  ✅ Attached $POLICY_ARN"
  else
    echo "  ⏭️  Already attached: $POLICY_ARN"
  fi
done

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo ""
echo "✅ Done! Add this as a GitHub Secret:"
echo "   AWS_IAM_ROLE_ARN = $ROLE_ARN"
