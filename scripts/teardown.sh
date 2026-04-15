#!/usr/bin/env bash
# Delete the Hermes Agent CloudFormation stack
set -euo pipefail

STACK_NAME="${1:-hermes-agent}"
REGION="${2:-$(aws configure get region 2>/dev/null || echo us-east-1)}"

echo "Deleting stack: $STACK_NAME (region: $REGION)"
read -p "Are you sure? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
echo "Waiting for deletion..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
echo "✅ Stack deleted."
