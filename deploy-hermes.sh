#!/usr/bin/env bash
# =============================================================================
# Hermes Agent One-Click Deployment Script
# =============================================================================
# Deploys Hermes Agent on AWS EC2 (Singapore) with:
#   - c7g.xlarge Graviton3 instance
#   - AWS Bedrock (Claude Sonnet 4) as LLM provider
#   - Bedrock auxiliary patch for context compression/memory
#   - WeChat gateway with interactive QR login
#
# Prerequisites:
#   - AWS CLI configured with permissions for EC2, IAM, Bedrock
#   - ssh-keygen available
#
# Usage:
#   ./deploy-hermes.sh          # Full deploy + WeChat QR login
#   ./deploy-hermes.sh --skip-ec2  # Skip EC2 creation, use existing instance
# =============================================================================

set -Eeuo pipefail

export AWS_PAGER=""

# Fail-fast: print error location on any failure
trap 'echo -e "\n\033[0;31m[✗] Error at line ${LINENO} (exit code: $?)\033[0m"' ERR

# ---------------------------------------------------------------------------
# Configuration (override via env vars or ~/.hermes-deploy.conf)
# ---------------------------------------------------------------------------
[[ -f "${HOME}/.hermes-deploy.conf" ]] && source "${HOME}/.hermes-deploy.conf"

REGION="${HERMES_REGION:-ap-southeast-1}"
INSTANCE_TYPE="${HERMES_INSTANCE_TYPE:-c7g.xlarge}"
KEY_NAME="${HERMES_KEY_NAME:-hermes-agent-key}"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
SG_NAME="${HERMES_SG_NAME:-hermes-agent-sg}"
IAM_ROLE="${HERMES_IAM_ROLE:-hermes-agent-role}"
IAM_PROFILE="${HERMES_IAM_PROFILE:-hermes-agent-profile}"
BEDROCK_MODEL="${HERMES_BEDROCK_MODEL:-apac.anthropic.claude-sonnet-4-20250514-v1:0}"
VOLUME_SIZE="${HERMES_VOLUME_SIZE:-30}"
HERMES_USER="hermes"
CLOUD_INIT_TIMEOUT="${HERMES_CLOUD_INIT_TIMEOUT:-900}"  # 15 min max
SSH_TIMEOUT="${HERMES_SSH_TIMEOUT:-600}"                 # 10 min max

# Resolve script directory (for scripts/ subfolder)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}"; }

ssh_cmd() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -i "$KEY_FILE" "ec2-user@${PUBLIC_IP}" "$@"
}

ssh_hermes() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -i "$KEY_FILE" "ec2-user@${PUBLIC_IP}" \
        "sudo su - ${HERMES_USER} -c '$(echo "$1" | sed "s/'/'\\\\''/g")'"
}

# ---------------------------------------------------------------------------
# Interactive selection (skipped if values are pre-set via env / config file)
# ---------------------------------------------------------------------------

# Region selection
select_region() {
    echo ""
    echo -e "${BOLD}Select Region:${NC}"
    echo ""
    local regions=(
        "ap-southeast-1|Singapore"
        "ap-northeast-1|Tokyo"
        "ap-northeast-2|Seoul"
        "ap-south-1|Mumbai"
        "us-east-1|N. Virginia"
        "us-west-2|Oregon"
        "eu-west-1|Ireland"
        "eu-central-1|Frankfurt"
    )
    local i=1
    for entry in "${regions[@]}"; do
        local code="${entry%%|*}"
        local label="${entry##*|}"
        local marker="  "
        [[ "$code" == "$REGION" ]] && marker="${GREEN}▸ ${NC}"
        printf "    ${marker}%d) %-20s %s\n" "$i" "$code" "$label"
        (( i++ ))
    done
    echo ""
    read -p "  Enter number [default: ${REGION}]: " choice
    if [[ -n "$choice" && "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#regions[@]} ]]; then
        REGION="${regions[$((choice-1))]%%|*}"
    fi
}

# Instance type selection
select_instance_type() {
    echo ""
    echo -e "${BOLD}Select Instance Type:${NC}"
    echo ""
    local types=(
        "c7g.medium|1 vCPU,  2 GiB  — Light testing"
        "c7g.large|2 vCPU,  4 GiB  — Small scale"
        "c7g.xlarge|4 vCPU,  8 GiB  — Recommended (default)"
        "c7g.2xlarge|8 vCPU, 16 GiB  — High concurrency"
        "m7g.xlarge|4 vCPU, 16 GiB  — Memory intensive"
        "m7g.2xlarge|8 vCPU, 32 GiB  — Memory + high concurrency"
    )
    local i=1
    for entry in "${types[@]}"; do
        local code="${entry%%|*}"
        local label="${entry##*|}"
        local marker="  "
        [[ "$code" == "$INSTANCE_TYPE" ]] && marker="${GREEN}▸ ${NC}"
        printf "    ${marker}%d) %-16s %s\n" "$i" "$code" "$label"
        (( i++ ))
    done
    echo ""
    read -p "  Enter number [default: ${INSTANCE_TYPE}]: " choice
    if [[ -n "$choice" && "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#types[@]} ]]; then
        INSTANCE_TYPE="${types[$((choice-1))]%%|*}"
    fi
}

# Only show interactive menus for full deploy (not --skip-ec2) and when not pre-configured
if [[ "${1:-}" != "--skip-ec2" ]]; then
    # Show selection if no explicit env var / config override was set
    if [[ -z "${HERMES_REGION:-}" ]]; then
        select_region
    fi
    if [[ -z "${HERMES_INSTANCE_TYPE:-}" ]]; then
        select_instance_type
    fi
    echo ""
    log "Region: ${REGION}, Instance: ${INSTANCE_TYPE}"
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
step "Pre-flight Checks"

command -v aws >/dev/null 2>&1 || err "AWS CLI not found. Install: https://aws.amazon.com/cli/"
aws sts get-caller-identity >/dev/null 2>&1 || err "AWS credentials not configured"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "AWS Account: ${ACCOUNT_ID}"
log "Target Region: ${REGION}"

# ---------------------------------------------------------------------------
# 1. IAM Role + Instance Profile
# ---------------------------------------------------------------------------
if [[ "${1:-}" != "--skip-ec2" ]]; then

step "1/7 — IAM Role & Instance Profile"

if aws iam get-role --role-name "$IAM_ROLE" >/dev/null 2>&1; then
    log "IAM role ${IAM_ROLE} already exists"
else
    log "Creating IAM role ${IAM_ROLE}..."
    aws iam create-role --role-name "$IAM_ROLE" \
        --assume-role-policy-document '{
            "Version":"2012-10-17",
            "Statement":[{
                "Effect":"Allow",
                "Principal":{"Service":"ec2.amazonaws.com"},
                "Action":"sts:AssumeRole"
            }]
        }' --output text --query 'Role.Arn'
fi

# Attach Bedrock + SSM policies
aws iam put-role-policy --role-name "$IAM_ROLE" --policy-name BedrockAccess \
    --policy-document '{
        "Version":"2012-10-17",
        "Statement":[{
            "Sid":"BedrockFull","Effect":"Allow",
            "Action":[
                "bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream",
                "bedrock:ListFoundationModels","bedrock:GetFoundationModel",
                "bedrock:ListInferenceProfiles","bedrock:GetInferenceProfile",
                "bedrock:Converse","bedrock:ConverseStream"
            ],
            "Resource":"*"
        }]
    }' 2>/dev/null
aws iam attach-role-policy --role-name "$IAM_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
log "IAM policies configured"

if aws iam get-instance-profile --instance-profile-name "$IAM_PROFILE" >/dev/null 2>&1; then
    log "Instance profile ${IAM_PROFILE} already exists"
else
    aws iam create-instance-profile --instance-profile-name "$IAM_PROFILE" >/dev/null
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$IAM_PROFILE" --role-name "$IAM_ROLE" >/dev/null
    log "Instance profile created (waiting 10s for propagation...)"
    sleep 10
fi

# ---------------------------------------------------------------------------
# 2. SSH Key Pair
# ---------------------------------------------------------------------------
step "2/7 — SSH Key Pair"

if [[ -f "$KEY_FILE" ]]; then
    # Verify key exists in AWS
    if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
        log "SSH key ${KEY_NAME} exists locally and in AWS"
    else
        warn "Local key exists but not in AWS — recreating"
        rm -f "$KEY_FILE"
    fi
fi

if [[ ! -f "$KEY_FILE" ]]; then
    aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME" 2>/dev/null || true
    aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
        --key-type ed25519 --query 'KeyMaterial' --output text > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    log "SSH key created: ${KEY_FILE}"
fi

# ---------------------------------------------------------------------------
# 3. Security Group
# ---------------------------------------------------------------------------
step "3/7 — Security Group"

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --query 'Vpcs[?IsDefault].VpcId' --output text)

SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
    SG_ID=$(aws ec2 create-security-group --region "$REGION" \
        --group-name "$SG_NAME" --description "Hermes Agent SSH" \
        --vpc-id "$VPC_ID" --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --region "$REGION" \
        --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
    log "Security group created: ${SG_ID}"
else
    log "Security group exists: ${SG_ID}"
fi

# ---------------------------------------------------------------------------
# 4. Launch EC2 Instance
# ---------------------------------------------------------------------------
step "4/7 — Launch EC2 Instance"

# Find latest Amazon Linux 2023 ARM64 AMI
AMI_ID=$(aws ec2 describe-images --region "$REGION" --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-arm64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
log "AMI: ${AMI_ID}"

# User-data: install Hermes + dependencies
USERDATA_FILE="${SCRIPT_DIR}/scripts/userdata.sh"
[[ -f "$USERDATA_FILE" ]] || err "Missing ${USERDATA_FILE} — ensure scripts/ directory is alongside deploy-hermes.sh"
USERDATA=$(cat "$USERDATA_FILE")

INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=${IAM_PROFILE}" \
    --user-data "$USERDATA" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\",\"Encrypted\":true}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=hermes-agent},{Key=Project,Value=hermes-agent}]" \
    --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
    --query 'Instances[0].InstanceId' --output text)

log "Instance launched: ${INSTANCE_ID}"
echo -n "    Waiting for running state..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
echo " done"

PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
log "Public IP: ${PUBLIC_IP}"

# Save instance info for --skip-ec2 reruns
cat > "$HOME/.hermes-deploy-info" << EOF
INSTANCE_ID=${INSTANCE_ID}
PUBLIC_IP=${PUBLIC_IP}
REGION=${REGION}
EOF

else
    # --skip-ec2: load existing instance info
    step "Loading Existing Instance"
    if [[ -f "$HOME/.hermes-deploy-info" ]]; then
        source "$HOME/.hermes-deploy-info"
        log "Using existing instance: ${INSTANCE_ID} (${PUBLIC_IP})"
    else
        err "No deploy info found. Run without --skip-ec2 first."
    fi
fi

# ---------------------------------------------------------------------------
# 5. Wait for Installation to Complete
# ---------------------------------------------------------------------------
step "5/7 — Waiting for Hermes Installation"

SSH_INTERVAL=10
SSH_MAX_ATTEMPTS=$(( SSH_TIMEOUT / SSH_INTERVAL ))
echo -n "    Waiting for SSH (timeout: ${SSH_TIMEOUT}s)..."
for (( i=1; i<=SSH_MAX_ATTEMPTS; i++ )); do
    if ssh_cmd "echo ok" >/dev/null 2>&1; then break; fi
    if (( i == SSH_MAX_ATTEMPTS )); then err "SSH connection timed out after ${SSH_TIMEOUT}s"; fi
    echo -n "."
    sleep "$SSH_INTERVAL"
done
echo " connected"

CLOUD_INIT_INTERVAL=15
CLOUD_INIT_MAX_ATTEMPTS=$(( CLOUD_INIT_TIMEOUT / CLOUD_INIT_INTERVAL ))
echo -n "    Waiting for cloud-init (timeout: ${CLOUD_INIT_TIMEOUT}s)..."
for (( i=1; i<=CLOUD_INIT_MAX_ATTEMPTS; i++ )); do
    STATUS=$(ssh_cmd "cloud-init status 2>/dev/null | grep -oP 'status: \K\w+'" 2>/dev/null || echo "running")
    if [[ "$STATUS" == "done" || "$STATUS" == "error" ]]; then break; fi
    if (( i == CLOUD_INIT_MAX_ATTEMPTS )); then
        warn "cloud-init timed out after ${CLOUD_INIT_TIMEOUT}s (status: ${STATUS})"
    fi
    echo -n "."
    sleep "$CLOUD_INIT_INTERVAL"
done
echo " ${STATUS}"

# Verify Hermes is installed
HERMES_VER=$(ssh_cmd "sudo su - hermes -c 'hermes --version 2>/dev/null'" 2>/dev/null | head -1)
if [[ -z "$HERMES_VER" ]]; then
    err "Hermes installation failed. Check: ssh -i ${KEY_FILE} ec2-user@${PUBLIC_IP} 'cat /var/log/hermes-setup.log'"
fi
log "Installed: ${HERMES_VER}"

# ---------------------------------------------------------------------------
# 6. Configure Hermes for Bedrock
# ---------------------------------------------------------------------------
step "6/7 — Configuring Hermes for AWS Bedrock"

# Update config.yaml for Bedrock provider
ssh_cmd << REMOTE_CFG
sudo su - hermes -c "
    sed -i 's|^  default: .*|  default: \"${BEDROCK_MODEL}\"|' ~/.hermes/config.yaml
    sed -i 's|^  provider: .*|  provider: \"bedrock\"|' ~/.hermes/config.yaml
    sed -i 's|^  base_url: .*|  base_url: \"https://bedrock-runtime.${REGION}.amazonaws.com\"|' ~/.hermes/config.yaml
"
# Set AWS region in hermes user profile
echo 'export AWS_DEFAULT_REGION=${REGION}' | sudo tee -a /home/hermes/.bashrc >/dev/null
echo 'export AWS_REGION=${REGION}' | sudo tee -a /home/hermes/.bashrc >/dev/null
REMOTE_CFG
log "Bedrock provider configured (model: ${BEDROCK_MODEL})"

# Apply Bedrock auxiliary patch
PATCH_FILE="${SCRIPT_DIR}/scripts/bedrock-patch.py"
[[ -f "$PATCH_FILE" ]] || err "Missing ${PATCH_FILE}"
scp -o StrictHostKeyChecking=no -i "$KEY_FILE" "$PATCH_FILE" "ec2-user@${PUBLIC_IP}:/tmp/bedrock-patch.py"
ssh_cmd "sudo su - hermes -c 'source ~/.hermes/hermes-agent/venv/bin/activate && cd ~/.hermes/hermes-agent && python3 /tmp/bedrock-patch.py'"
log "Bedrock auxiliary patch applied"

# Setup sudoers for hermes user
ssh_cmd << 'SUDOERS_CMD'
sudo tee /etc/sudoers.d/hermes-gateway > /dev/null << 'EOF'
hermes ALL=(ALL) NOPASSWD: /usr/bin/systemctl status hermes-gateway *
hermes ALL=(ALL) NOPASSWD: /usr/bin/systemctl status hermes-gateway
hermes ALL=(ALL) NOPASSWD: /usr/bin/systemctl start hermes-gateway
hermes ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop hermes-gateway
hermes ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hermes-gateway
hermes ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable hermes-gateway
hermes ALL=(ALL) NOPASSWD: /usr/bin/systemctl disable hermes-gateway
hermes ALL=(ALL) NOPASSWD: /usr/bin/journalctl *hermes-gateway*
hermes ALL=(ALL) NOPASSWD: /home/hermes/.local/bin/hermes gateway *
EOF
sudo chmod 440 /etc/sudoers.d/hermes-gateway
SUDOERS_CMD
log "Sudoers configured for gateway management"

# Verify Bedrock connectivity
BEDROCK_TEST=$(ssh_cmd "export AWS_DEFAULT_REGION=${REGION}; aws bedrock-runtime converse --region ${REGION} --model-id ${BEDROCK_MODEL} --messages '[{\"role\":\"user\",\"content\":[{\"text\":\"say ok\"}]}]' --inference-config '{\"maxTokens\":10}' --query 'output.message.content[0].text' --output text 2>&1" || echo "FAIL")
if [[ "$BEDROCK_TEST" == *"FAIL"* || "$BEDROCK_TEST" == *"error"* ]]; then
    warn "Bedrock test failed: ${BEDROCK_TEST}"
    warn "Continuing — you may need to request model access in the AWS console"
else
    log "Bedrock verified: model responded '${BEDROCK_TEST}'"
fi

# ---------------------------------------------------------------------------
# 7. WeChat QR Login + Gateway Setup
# ---------------------------------------------------------------------------
step "7/7 — WeChat Gateway Setup (QR Login)"

echo ""
echo -e "  ${BOLD}WeChat QR code will be displayed next${NC}"
echo -e "  ${BOLD}Scan with WeChat to log in${NC}"
echo ""
read -p "  Press Enter to start QR login..." _

# Run the WeChat QR login interactively via SSH with TTY
ssh -t -o StrictHostKeyChecking=no -i "$KEY_FILE" "ec2-user@${PUBLIC_IP}" \
    "sudo su - hermes -c 'export AWS_DEFAULT_REGION=${REGION} AWS_REGION=${REGION}; hermes gateway setup'"

# After setup: install service, auto-configure DM policy & user allowlist
GATEWAY_FILE="${SCRIPT_DIR}/scripts/gateway-setup.sh"
[[ -f "$GATEWAY_FILE" ]] || err "Missing ${GATEWAY_FILE}"
scp -o StrictHostKeyChecking=no -i "$KEY_FILE" "$GATEWAY_FILE" "ec2-user@${PUBLIC_IP}:/tmp/gateway-setup.sh"
ssh_cmd "chmod +x /tmp/gateway-setup.sh && HERMES_REGION=${REGION} /tmp/gateway-setup.sh"

# ---------------------------------------------------------------------------
# Done!
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║           ☤ Hermes Agent Deploy Complete!                    ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Instance Info${NC}"
echo -e "    Instance ID:  ${CYAN}${INSTANCE_ID}${NC}"
echo -e "    Public IP:    ${CYAN}${PUBLIC_IP}${NC}"
echo -e "    Region:       ${CYAN}${REGION}${NC}"
echo -e "    Model:        ${CYAN}${BEDROCK_MODEL}${NC}"
echo ""
echo -e "  ${BOLD}Connect${NC}"
echo -e "    ssh -i ${KEY_FILE} ec2-user@${PUBLIC_IP}"
echo -e "    sudo su - hermes"
echo -e "    hermes    # Start interactive terminal"
echo ""
echo -e "  ${BOLD}Gateway Management${NC}"
echo -e "    sudo systemctl status hermes-gateway   # Check status"
echo -e "    sudo systemctl restart hermes-gateway   # Restart"
echo -e "    journalctl -u hermes-gateway -f         # Live logs"
echo ""
echo -e "  ${BOLD}WeChat is ready — send a message to Hermes! 💬${NC}"
echo ""

# Save deploy info
cat > "$HOME/.hermes-deploy-info" << EOF
INSTANCE_ID=${INSTANCE_ID}
PUBLIC_IP=${PUBLIC_IP}
REGION=${REGION}
KEY_FILE=${KEY_FILE}
BEDROCK_MODEL=${BEDROCK_MODEL}
DEPLOYED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
log "Deploy info saved to ~/.hermes-deploy-info"
