#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# generate-ssh-keys.sh
# Run this ONCE locally to generate the SSH key pair.
# The public key content is stored in GitHub Secret SSH_PUBLIC_KEY,
# and Terraform uses it to create the AWS key pair automatically.
# The private key is stored in GitHub Secret SSH_PRIVATE_KEY
# for Ansible to SSH into the EC2 instances.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

KEY_NAME="deployer_key"
OUTPUT_DIR="./keys"

echo "══════════════════════════════════════════════════"
echo " This script generates a new SSH key pair."
echo " You must then:"
echo ""
echo "  1. Add both keys as GitHub Secrets (script does this automatically):"
echo "     SSH_PRIVATE_KEY  →  Contents of: $OUTPUT_DIR/$KEY_NAME"
echo "     SSH_PUBLIC_KEY   →  Contents of: $OUTPUT_DIR/${KEY_NAME}.pub"
echo ""
echo "  2. Terraform will create the AWS key pair automatically"
echo "     from the SSH_PUBLIC_KEY secret when you run the pipeline."
echo "══════════════════════════════════════════════════"
echo ""

mkdir -p "$OUTPUT_DIR"

ssh-keygen -t rsa -b 4096 -f "$OUTPUT_DIR/$KEY_NAME" -N "" -C "github-actions-deployer"

echo ""
echo "══════════════════════════════════════════════════"
echo " Keys generated in: $OUTPUT_DIR/"
echo "══════════════════════════════════════════════════"
echo ""

# ──────────────────────────────────────────────────────────────
# Auto-upload keys as GitHub Secrets
# ──────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────"
echo " Uploading keys to GitHub Secrets..."
echo "──────────────────────────────────────────────────"

if ! command -v gh &> /dev/null; then
    echo ""
    echo "⚠️  gh CLI not found. Please install it:"
    echo "   https://cli.github.com/"
    echo ""
    echo "Then manually add these as GitHub Secrets:"
    echo ""
    echo "  SSH_PRIVATE_KEY  →  Contents of: $OUTPUT_DIR/$KEY_NAME"
    echo "  SSH_PUBLIC_KEY   →  Contents of: $OUTPUT_DIR/${KEY_NAME}.pub"
    exit 0
fi

if ! gh auth status &> /dev/null; then
    echo ""
    echo "⚠️  gh CLI is not authenticated. Please run:"
    echo "   gh auth login"
    echo ""
    echo "Then manually add these as GitHub Secrets:"
    echo ""
    echo "  SSH_PRIVATE_KEY  →  Contents of: $OUTPUT_DIR/$KEY_NAME"
    echo "  SSH_PUBLIC_KEY   →  Contents of: $OUTPUT_DIR/${KEY_NAME}.pub"
    exit 0
fi

REPO="$(gh repo view --json nameWithOwner -q '.nameWithOwner')"

echo ""
echo "Setting SSH_PRIVATE_KEY..."
gh secret set SSH_PRIVATE_KEY --repo "${REPO:?}" --body "$(cat "$OUTPUT_DIR/$KEY_NAME")"

echo ""
echo "Setting SSH_PUBLIC_KEY..."
gh secret set SSH_PUBLIC_KEY --repo "${REPO:?}" --body "$(cat "$OUTPUT_DIR/${KEY_NAME}.pub")"

echo ""
echo "══════════════════════════════════════════════════"
echo "✅ Secrets added successfully to ${REPO}!"
echo "══════════════════════════════════════════════════"
echo ""
echo "  SSH_PRIVATE_KEY"
echo "  SSH_PUBLIC_KEY"
echo ""

echo "⚠️  NEVER commit the private key to Git!"
echo "   Ensure 'keys/' is in .gitignore"
