#!/usr/bin/env bash
# Check the status of a Hermes Agent deployment
set -euo pipefail

STACK_NAME="${1:-hermes-agent}"
REGION="${2:-$(aws configure get region 2>/dev/null || echo us-east-1)}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Stack: $STACK_NAME"
echo "  Region: $REGION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Stack status
STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")

echo "Stack Status: $STATUS"
echo ""

if [ "$STATUS" = "NOT_FOUND" ]; then
    echo "Stack not found."
    exit 1
fi

# Outputs
echo "Outputs:"
aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table 2>/dev/null

# Instance status
INSTANCE_ID=$(aws cloudformation describe-stack-resource \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --logical-resource-id HermesInstance \
    --query 'StackResourceDetail.PhysicalResourceId' --output text 2>/dev/null || echo "")

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    echo ""
    echo "Instance: $INSTANCE_ID"
    aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
        --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress,InstanceType]' \
        --output table 2>/dev/null
fi
