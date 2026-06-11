#!/bin/bash
# scripts/01_setup_aws_oidc.sh
# -----------------------------
# Creates an IAM OIDC Provider and Role so GitHub Actions can assume
# AWS credentials without storing long-lived access keys.
#
# Usage:
#   chmod +x scripts/01_setup_aws_oidc.sh
#   ./scripts/01_setup_aws_oidc.sh
#
# Prerequisites:
#   - AWS CLI configured with AdministratorAccess
#   - Change GITHUB_ORG and GITHUB_REPO below

set -euo pipefail

# ---- CONFIGURATION ---- Edit these ----
GITHUB_ORG="mrbalraj007"
GITHUB_REPO="aws-oidc-terraform-ansible-cicd"
GITHUB_BRANCH="main"
AWS_REGION="us-east-1"
ROLE_NAME="github-actions-oidc-role"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> Account ID : $ACCOUNT_ID"
echo "==> GitHub     : $GITHUB_ORG/$GITHUB_REPO"
echo "==> Region     : $AWS_REGION"

# ---- Create OIDC Provider ----
OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

echo ""
echo "==> Creating OIDC Provider..."
aws iam create-open-id-connect-provider \
  --url "$OIDC_URL" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "$OIDC_THUMBPRINT" \
  --region "$AWS_REGION" 2>/dev/null || echo "   (OIDC provider may already exist – skipping)"

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

# ---- Create Trust Policy ----
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF

# ---- Create IAM Role ----
echo ""
echo "==> Creating IAM Role: $ROLE_NAME"
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --description "Used by GitHub Actions OIDC for $GITHUB_ORG/$GITHUB_REPO" 2>/dev/null \
  || echo "   (Role may already exist – skipping)"

# Attach policies (adjust to least-privilege for production)
echo "==> Attaching policies..."
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonS3FullAccess"
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/IAMFullAccess"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# ---- Add AWS_IAM_ROLE_ARN secret to GitHub Actions ----
echo ""
echo "==> Adding AWS_IAM_ROLE_ARN secret to GitHub Actions..."
gh secret set AWS_IAM_ROLE_ARN --body "$ROLE_ARN" \
  --repo "$GITHUB_ORG/$GITHUB_REPO"

# ---- Prompt for WinRM password and add to GitHub Actions ----
echo ""
echo "==> WinRM Password Setup"
echo "   This password will be used for the Windows EC2 admin account"
echo ""
read -r -p "Enter a strong password for WinRM (min 12 chars): " -s WINRM_PASSWORD
echo ""

if [ -z "${WINRM_PASSWORD}" ]; then
  echo "ERROR: Password cannot be empty"
  exit 1
fi

PWD_LEN=${#WINRM_PASSWORD}
if [ "$PWD_LEN" -lt 12 ]; then
  echo "ERROR: Password must be at least 12 characters. Got: $PWD_LEN"
  exit 1
fi

echo "==> Adding TF_VAR_winrm_password secret to GitHub Actions..."
gh secret set TF_VAR_winrm_password --body "$WINRM_PASSWORD" \
  --repo "$GITHUB_ORG/$GITHUB_REPO"

echo ""
echo "=============================================="
echo "OIDC setup complete!"
echo "  Name : AWS_IAM_ROLE_ARN"
echo "  Value: $ROLE_ARN"
echo ""
echo "=============================================="
echo "WinRM password secret set!"
echo "  Name : TF_VAR_winrm_password"
echo "=============================================="

rm -f /tmp/trust-policy.json