#!/usr/bin/env bash
# ============================================================================
# Hermes Agent AWS Deploy Script
# Usage: ./deploy.sh [--region REGION] [--key KEY_NAME] [--stack STACK_NAME]
# ============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}→${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*"; }

# ============================================================================
# Defaults
# ============================================================================
STACK_NAME="hermes-agent"
REGION=""
KEY_NAME=""
INSTANCE_TYPE="t3.medium"
SSH_CIDR="0.0.0.0/0"
ENABLE_BEDROCK="true"
INSTALL_LITELLM="true"
BEDROCK_REGION=""
TEMPLATE="full"
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================================
# Parse args
# ============================================================================
usage() {
    cat << EOF
${BOLD}Hermes Agent AWS Deploy${NC}

Usage: $0 [OPTIONS]

Options:
  --region REGION        AWS region for EC2 (default: interactive)
  --key KEY_NAME         EC2 Key Pair name (default: interactive)
  --stack NAME           CloudFormation stack name (default: hermes-agent)
  --instance-type TYPE   EC2 instance type (default: t3.medium)
  --ssh-cidr CIDR        SSH allow CIDR (default: 0.0.0.0/0)
  --no-bedrock           Skip Bedrock IAM role and LiteLLM
  --bedrock-region REG   Region for Bedrock API (default: same as --region)
  --minimal              Use minimal template (no Bedrock, no LiteLLM)
  --dry-run              Print the AWS CLI command without executing
  -h, --help             Show this help

Examples:
  # Interactive setup
  $0

  # One-liner deploy to Singapore
  $0 --region ap-southeast-1 --key my-key --ssh-cidr 203.0.113.50/32

  # Minimal deploy (no Bedrock)
  $0 --minimal --region us-east-1 --key my-key
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --region)          REGION="$2"; shift 2 ;;
        --key)             KEY_NAME="$2"; shift 2 ;;
        --stack)           STACK_NAME="$2"; shift 2 ;;
        --instance-type)   INSTANCE_TYPE="$2"; shift 2 ;;
        --ssh-cidr)        SSH_CIDR="$2"; shift 2 ;;
        --no-bedrock)      ENABLE_BEDROCK="false"; INSTALL_LITELLM="false"; shift ;;
        --bedrock-region)  BEDROCK_REGION="$2"; shift 2 ;;
        --minimal)         TEMPLATE="minimal"; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        -h|--help)         usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
done

# ============================================================================
# Pre-flight checks
# ============================================================================
log "Checking prerequisites..."

if ! command -v aws &>/dev/null; then
    err "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
    err "AWS credentials not configured. Run: aws configure"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ok "AWS Account: $ACCOUNT_ID"

# ============================================================================
# Interactive prompts (if args not provided)
# ============================================================================
if [ -z "$REGION" ]; then
    echo ""
    echo -e "${BOLD}Select AWS Region:${NC}"
    echo "  1) us-east-1      (N. Virginia)"
    echo "  2) us-west-2      (Oregon)"
    echo "  3) eu-west-1      (Ireland)"
    echo "  4) ap-southeast-1 (Singapore)"
    echo "  5) ap-northeast-1 (Tokyo)"
    echo ""
    read -p "Enter choice [1-5] (default: 4): " choice
    case "${choice:-4}" in
        1) REGION="us-east-1" ;;
        2) REGION="us-west-2" ;;
        3) REGION="eu-west-1" ;;
        4) REGION="ap-southeast-1" ;;
        5) REGION="ap-northeast-1" ;;
        *) REGION="ap-southeast-1" ;;
    esac
fi
ok "Region: $REGION"

if [ -z "$BEDROCK_REGION" ]; then
    BEDROCK_REGION="$REGION"
fi

if [ -z "$KEY_NAME" ]; then
    echo ""
    log "Available Key Pairs in $REGION:"
    aws ec2 describe-key-pairs --region "$REGION" \
        --query 'KeyPairs[*].KeyName' --output table 2>/dev/null || true
    echo ""
    read -p "Enter Key Pair name: " KEY_NAME
    if [ -z "$KEY_NAME" ]; then
        err "Key Pair name is required"
        exit 1
    fi
fi
ok "Key Pair: $KEY_NAME"

# Detect public IP for SSH CIDR suggestion
if [ "$SSH_CIDR" = "0.0.0.0/0" ]; then
    MY_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo "")
    if [ -n "$MY_IP" ]; then
        echo ""
        read -p "Restrict SSH to your IP ($MY_IP/32)? [Y/n]: " restrict
        if [[ "${restrict:-Y}" =~ ^[Yy]$ ]]; then
            SSH_CIDR="${MY_IP}/32"
            ok "SSH restricted to: $SSH_CIDR"
        fi
    fi
fi

# ============================================================================
# Select template
# ============================================================================
if [ "$TEMPLATE" = "minimal" ]; then
    TEMPLATE_FILE="$REPO_DIR/cloudformation/hermes-agent-minimal.yaml"
    PARAMS=(
        "ParameterKey=KeyPairName,ParameterValue=$KEY_NAME"
        "ParameterKey=InstanceType,ParameterValue=$INSTANCE_TYPE"
        "ParameterKey=SSHAllowCIDR,ParameterValue=$SSH_CIDR"
    )
    CAPABILITIES=""
else
    TEMPLATE_FILE="$REPO_DIR/cloudformation/hermes-agent.yaml"
    PARAMS=(
        "ParameterKey=KeyPairName,ParameterValue=$KEY_NAME"
        "ParameterKey=InstanceType,ParameterValue=$INSTANCE_TYPE"
        "ParameterKey=SSHAllowCIDR,ParameterValue=$SSH_CIDR"
        "ParameterKey=EnableBedrockAccess,ParameterValue=$ENABLE_BEDROCK"
        "ParameterKey=InstallLiteLLM,ParameterValue=$INSTALL_LITELLM"
        "ParameterKey=BedrockRegion,ParameterValue=$BEDROCK_REGION"
    )
    CAPABILITIES="--capabilities CAPABILITY_NAMED_IAM"
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
    err "Template not found: $TEMPLATE_FILE"
    exit 1
fi

# ============================================================================
# Deploy
# ============================================================================
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Deployment Summary${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  Stack:          $STACK_NAME"
echo "  Region:         $REGION"
echo "  Template:       $(basename $TEMPLATE_FILE)"
echo "  Instance:       $INSTANCE_TYPE"
echo "  Key Pair:       $KEY_NAME"
echo "  SSH CIDR:       $SSH_CIDR"
echo "  Bedrock:        $ENABLE_BEDROCK"
echo "  LiteLLM:        $INSTALL_LITELLM"
echo "  Bedrock Region: $BEDROCK_REGION"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

CMD="aws cloudformation create-stack \
  --stack-name $STACK_NAME \
  --template-body file://$TEMPLATE_FILE \
  --parameters ${PARAMS[*]} \
  --region $REGION \
  --tags Key=Project,Value=hermes-agent \
  $CAPABILITIES"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}Dry run — command to execute:${NC}"
    echo ""
    echo "$CMD"
    exit 0
fi

read -p "Deploy now? [Y/n]: " confirm
if [[ ! "${confirm:-Y}" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

log "Creating stack..."
eval "$CMD"
ok "Stack creation initiated: $STACK_NAME"

echo ""
log "Waiting for deployment to complete (~10 minutes)..."
log "You can monitor progress in the AWS Console:"
echo "  https://${REGION}.console.aws.amazon.com/cloudformation/home?region=${REGION}#/stacks"
echo ""

if aws cloudformation wait stack-create-complete \
    --stack-name "$STACK_NAME" --region "$REGION" 2>/dev/null; then

    echo ""
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  ✅ Deployment Complete!${NC}"
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Fetch outputs
    PUBLIC_IP=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`PublicIP`].OutputValue' --output text)

    echo "  Public IP:  $PUBLIC_IP"
    echo ""
    echo "  Connect:"
    echo "    ssh ubuntu@$PUBLIC_IP"
    echo ""
    echo "  First-time setup:"
    echo "    hermes setup"
    echo "    hermes"
    echo ""
else
    err "Stack creation failed. Check the CloudFormation console for details."
    aws cloudformation describe-stack-events \
        --stack-name "$STACK_NAME" --region "$REGION" \
        --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
        --output table 2>/dev/null || true
    exit 1
fi
