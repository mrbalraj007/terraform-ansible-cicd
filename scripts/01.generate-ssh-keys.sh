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
echo "NEXT STEPS:"
echo ""
echo "  1. Import public key to AWS (EC2 → Key Pairs → Import):"
echo "     aws ec2 import-key-pair \\"
echo "       --key-name \"$KEY_NAME\" \\"
echo "       --public-key-material \"fileb://$OUTPUT_DIR/${KEY_NAME}.pub\""
echo ""
echo "  2. Add this private key as GitHub Secret 'SSH_PRIVATE_KEY':"
echo ""
echo "Private key (copy everything including headers):"
echo "──────────────────────────────────────────────────"
cat "$OUTPUT_DIR/$KEY_NAME"
echo ""
echo "Public key (for AWS import):"
echo "──────────────────────────────────────────────────"
cat "$OUTPUT_DIR/${KEY_NAME}.pub"
echo ""
echo "⚠️  NEVER commit the private key to Git!"
echo "   Add keys/ to .gitignore"
