#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# generate-ssh-keys.sh
# Run this ONCE locally to generate the SSH key pair.
# Then upload the public key to AWS EC2 as a key pair named
# "MYLABKEY" (or your preferred name), and add the private key
# as a GitHub Secret.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

KEY_NAME="MYLABKEY2026"
OUTPUT_DIR="./keys"

echo "══════════════════════════════════════════════════"
echo " This script generates a new SSH key pair."
echo " You must then:"
echo ""
echo "  1. Import the public key into AWS EC2:"
echo "     aws ec2 import-key-pair \\"
echo "       --key-name \"$KEY_NAME\" \\"
echo "       --public-key-material \"fileb://$OUTPUT_DIR/${KEY_NAME}.pub\""
echo "       # Or via the AWS Console: EC2 → Key Pairs → Import"
echo ""
echo "  2. Add the private key as a GitHub Secret:"
echo "     SSH_PRIVATE_KEY  →  Contents of: $OUTPUT_DIR/$KEY_NAME"
echo ""
echo "  ⚠️  SSH_PUBLIC_KEY is NO LONGER needed as a GitHub Secret."
echo "     Terraform now references the existing key pair by name."
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
