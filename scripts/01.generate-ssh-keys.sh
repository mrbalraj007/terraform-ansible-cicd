#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# generate-ssh-keys.sh
# Run this ONCE locally to generate the SSH key pair.
# Then add the keys as GitHub Secrets.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

KEY_NAME="deployer_key"
OUTPUT_DIR="./keys"

mkdir -p "$OUTPUT_DIR"

ssh-keygen -t rsa -b 4096 -f "$OUTPUT_DIR/$KEY_NAME" -N "" -C "github-actions-deployer"

echo ""
echo "══════════════════════════════════════════════════"
echo " Keys generated in: $OUTPUT_DIR/"
echo "══════════════════════════════════════════════════"
echo ""
echo "Add these as GitHub Secrets:"
echo ""
echo "  SSH_PRIVATE_KEY  →  Contents of: $OUTPUT_DIR/$KEY_NAME"
echo "  SSH_PUBLIC_KEY   →  Contents of: $OUTPUT_DIR/${KEY_NAME}.pub"
echo ""
echo "Private key (copy everything including headers):"
echo "──────────────────────────────────────────────────"
cat "$OUTPUT_DIR/$KEY_NAME"
echo ""
echo "Public key:"
echo "──────────────────────────────────────────────────"
cat "$OUTPUT_DIR/${KEY_NAME}.pub"
echo ""
echo "⚠️  NEVER commit the private key to Git!"
echo "   Add keys/ to .gitignore"
