#!/usr/bin/env bash
# =============================================================================
# Hermes Agent Resource Cleanup Script
# =============================================================================
# Deletes all AWS resources created by deploy-hermes.sh:
#   - EC2 instance
#   - SSH key pair (AWS + local)
#   - Security group
#   - IAM instance profile / role / policies
#
# Usage:
#   ./cleanup-hermes.sh                        # Interactive — confirm before each step
#   ./cleanup-hermes.sh --force                 # Non-interactive — delete everything
#   ./cleanup-hermes.sh --region us-west-2      # Specify region explicitly
#   ./cleanup-hermes.sh --force --region eu-west-1
# =============================================================================

set -euo pipefail

export AWS_PAGER=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
FORCE=false
CLI_REGION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)  FORCE=true; shift ;;
        --region) CLI_REGION="$2"; shift 2 ;;
        --region=*) CLI_REGION="${1#*=}"; shift ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [--force] [--region REGION]"; exit 1 ;;
    esac
done

DEPLOY_INFO="$HOME/.hermes-deploy-info"

# Load region and other settings from deploy info if available,
# then allow CLI flag / env vars / defaults as fallback
if [[ -f "$DEPLOY_INFO" ]]; then
    source "$DEPLOY_INFO"
fi

# CLI --region takes highest precedence
[[ -n "$CLI_REGION" ]] && REGION="$CLI_REGION"

REGION="${REGION:-ap-southeast-1}"
KEY_NAME="${KEY_NAME:-hermes-agent-key}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME}.pem}"
SG_NAME="${SG_NAME:-hermes-agent-sg}"
IAM_ROLE="${IAM_ROLE:-hermes-agent-role}"
IAM_PROFILE="${IAM_PROFILE:-hermes-agent-profile}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
step() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}"; }

confirm() {
    if $FORCE; then return 0; fi
    read -p "  $1 [Y/n] " ans
    [[ ! "$ans" =~ ^[Nn] ]]
}

# ---------------------------------------------------------------------------
# Load deploy info
# ---------------------------------------------------------------------------
echo -e "${RED}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        ⚠  Hermes Agent Resource Cleanup                    ║"
echo "║        This will DELETE all Hermes AWS resources            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

INSTANCE_ID=""
if [[ -f "$DEPLOY_INFO" ]]; then
    source "$DEPLOY_INFO"
    echo -e "  Deploy info found: ${CYAN}${DEPLOY_INFO}${NC}"
    echo -e "    Instance ID:  ${INSTANCE_ID:-unknown}"
    echo -e "    Public IP:    ${PUBLIC_IP:-unknown}"
    echo -e "    Region:       ${REGION}"
    echo ""
else
    warn "No deploy info file found (${DEPLOY_INFO})"
    warn "Will scan for hermes-agent tagged instances"
fi

if ! $FORCE; then
    echo -e "  ${RED}${BOLD}This action is irreversible.${NC}"
    read -p "  Type 'DELETE' to proceed: " confirmation
    [[ "$confirmation" == "DELETE" ]] || { echo "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# 1. Terminate EC2 Instance(s)
# ---------------------------------------------------------------------------
step "1/5 — EC2 Instances"

# Only delete the specific instance recorded by deploy-hermes.sh
if [[ -z "${INSTANCE_ID:-}" ]]; then
    warn "No INSTANCE_ID in deploy info — nothing to terminate"
    INSTANCE_IDS=""
else
    # Verify it exists and is a hermes-agent instance
    STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "not-found")
    if [[ "$STATE" == "terminated" || "$STATE" == "not-found" ]]; then
        INSTANCE_IDS=""
    else
        INSTANCE_IDS="$INSTANCE_ID"
    fi
fi

if [[ -n "${INSTANCE_IDS// /}" ]]; then
    for iid in $INSTANCE_IDS; do
        IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$iid" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || echo "N/A")
        STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$iid" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")
        echo -e "    ${iid}  (${IP}, ${STATE})"
    done

    if confirm "Terminate these instance(s)?"; then
        aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS >/dev/null 2>&1
        log "Instances terminating: ${INSTANCE_IDS}"
        echo -n "    Waiting for termination..."
        aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS 2>/dev/null || true
        echo " done"
    else
        warn "Skipped instance termination"
    fi
else
    log "No hermes-agent instances found"
fi

# ---------------------------------------------------------------------------
# 2. Delete SSH Key Pair
# ---------------------------------------------------------------------------
step "2/5 — SSH Key Pair"

KEY_EXISTS=$(aws ec2 describe-key-pairs --region "$REGION" \
    --key-names "$KEY_NAME" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "None")

if [[ "$KEY_EXISTS" != "None" ]] || [[ -f "$KEY_FILE" ]]; then
    echo "    AWS key:   ${KEY_EXISTS}"
    echo "    Local key: ${KEY_FILE} ($([ -f "$KEY_FILE" ] && echo "exists" || echo "not found"))"

    if confirm "Delete SSH key pair?"; then
        aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME" 2>/dev/null || true
        rm -f "$KEY_FILE"
        log "SSH key pair deleted"
    else
        warn "Skipped SSH key deletion"
    fi
else
    log "No SSH key pair found"
fi

# ---------------------------------------------------------------------------
# 3. Delete Security Group
# ---------------------------------------------------------------------------
step "3/5 — Security Group"

SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)

if [[ -n "${SG_IDS// /}" ]]; then
    for sg in $SG_IDS; do
        echo "    ${sg} (${SG_NAME})"
    done

    if confirm "Delete security group(s)?"; then
        # Security groups may take a moment after instance termination
        for attempt in {1..6}; do
            DELETED=true
            for sg in $SG_IDS; do
                aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null && continue
                DELETED=false
            done
            $DELETED && break
            echo -n "    Waiting for dependencies to clear (${attempt}/6)..."
            sleep 10
            echo ""
        done
        log "Security group(s) deleted"
    else
        warn "Skipped security group deletion"
    fi
else
    log "No hermes-agent security group found"
fi

# ---------------------------------------------------------------------------
# 4. Delete IAM Instance Profile + Role
# ---------------------------------------------------------------------------
step "4/5 — IAM Role & Instance Profile"

PROFILE_EXISTS=$(aws iam get-instance-profile --instance-profile-name "$IAM_PROFILE" \
    --query 'InstanceProfile.InstanceProfileName' --output text 2>/dev/null || echo "None")
ROLE_EXISTS=$(aws iam get-role --role-name "$IAM_ROLE" \
    --query 'Role.RoleName' --output text 2>/dev/null || echo "None")

if [[ "$PROFILE_EXISTS" != "None" ]] || [[ "$ROLE_EXISTS" != "None" ]]; then
    echo "    Instance Profile: ${PROFILE_EXISTS}"
    echo "    IAM Role:         ${ROLE_EXISTS}"

    if confirm "Delete IAM role and instance profile?"; then
        # Remove role from instance profile
        if [[ "$PROFILE_EXISTS" != "None" ]]; then
            aws iam remove-role-from-instance-profile \
                --instance-profile-name "$IAM_PROFILE" --role-name "$IAM_ROLE" 2>/dev/null || true
            aws iam delete-instance-profile \
                --instance-profile-name "$IAM_PROFILE" 2>/dev/null || true
            log "Instance profile deleted"
        fi

        # Detach and delete role policies, then delete role
        if [[ "$ROLE_EXISTS" != "None" ]]; then
            # Detach managed policies
            ATTACHED=$(aws iam list-attached-role-policies --role-name "$IAM_ROLE" \
                --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
            for arn in $ATTACHED; do
                aws iam detach-role-policy --role-name "$IAM_ROLE" --policy-arn "$arn" 2>/dev/null || true
            done

            # Delete inline policies
            INLINE=$(aws iam list-role-policies --role-name "$IAM_ROLE" \
                --query 'PolicyNames[]' --output text 2>/dev/null || true)
            for name in $INLINE; do
                aws iam delete-role-policy --role-name "$IAM_ROLE" --policy-name "$name" 2>/dev/null || true
            done

            aws iam delete-role --role-name "$IAM_ROLE" 2>/dev/null || true
            log "IAM role deleted (detached ${ATTACHED:+managed policies, }${INLINE:+inline policies})"
        fi
    else
        warn "Skipped IAM deletion"
    fi
else
    log "No hermes-agent IAM resources found"
fi

# ---------------------------------------------------------------------------
# 5. Clean up local files
# ---------------------------------------------------------------------------
step "5/5 — Local Files"

LOCAL_FILES=()
[[ -f "$DEPLOY_INFO" ]] && LOCAL_FILES+=("$DEPLOY_INFO")

if [[ ${#LOCAL_FILES[@]} -gt 0 ]]; then
    for f in "${LOCAL_FILES[@]}"; do
        echo "    ${f}"
    done
    if confirm "Delete local deploy info files?"; then
        rm -f "${LOCAL_FILES[@]}"
        log "Local files cleaned up"
    else
        warn "Skipped local file cleanup"
    fi
else
    log "No local files to clean"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║           ☤ Hermes Agent Cleanup Complete                   ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Deleted resources in ${CYAN}${REGION}${NC}:"
echo -e "    EC2 instances:      ${INSTANCE_IDS:-none}"
echo -e "    SSH key pair:       ${KEY_NAME}"
echo -e "    Security group:     ${SG_NAME}"
echo -e "    IAM role/profile:   ${IAM_ROLE} / ${IAM_PROFILE}"
echo ""
