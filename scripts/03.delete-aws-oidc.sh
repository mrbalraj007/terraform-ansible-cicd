#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# delete-aws-oidc.sh
# Deletes the IAM Role + OIDC provider created by
# setup-aws-oidc.sh — reverses everything in the right order.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

ROLE_NAME="github-actions-terraform-role"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

echo "Account: $ACCOUNT_ID"
echo ""

# ── Detach and delete the IAM role ──────────────────────────
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "Detaching policies from role '$ROLE_NAME'..."
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[].PolicyArn" --output text)
  for POLICY_ARN in $ATTACHED_POLICIES; do
    echo "  Detaching $POLICY_ARN"
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
  done

  echo "Deleting role '$ROLE_NAME'..."
  aws iam delete-role --role-name "$ROLE_NAME"
  echo "  ✅ Role deleted"
else
  echo "⏭️  IAM role '$ROLE_NAME' does not exist — skipping"
fi

# ── Delete the OIDC provider ─────────────────────────────────
echo ""
if aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[].Arn" --output text | grep -q "$OIDC_PROVIDER_ARN"; then
  echo "Deleting OIDC provider..."
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN"
  echo "  ✅ OIDC provider deleted"
else
  echo "⏭️  OIDC provider does not exist — skipping"
fi

echo ""
echo "✅ Cleanup complete. All OIDC-related resources have been removed."