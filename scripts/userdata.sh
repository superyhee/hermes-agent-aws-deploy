#!/bin/bash
# =============================================================================
# Hermes Agent EC2 User-Data Script
# =============================================================================
# Runs as root during cloud-init to install Hermes Agent and dependencies.
# Log output: /var/log/hermes-setup.log
# =============================================================================

set -euxo pipefail
exec > /var/log/hermes-setup.log 2>&1

echo "=== Hermes Agent Setup Started $(date) ==="

# System packages
dnf update -y
dnf install -y git python3.11 python3.11-pip gcc python3.11-devel sqlite-devel

# Create hermes user
useradd -m -s /bin/bash hermes || true
mkdir -p /home/hermes/.hermes
chown -R hermes:hermes /home/hermes

# Allow hermes user to traverse /home/ec2-user (prevents PermissionError during git repo search)
chmod 755 /home/ec2-user

# Install as hermes user
su - hermes << 'INSTALL_EOF'
set -euxo pipefail
export PATH="$HOME/.local/bin:$PATH"

# Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

# Install Hermes Agent (non-interactive)
export HERMES_SKIP_SETUP=1
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash || true

# Install Bedrock dependencies
source ~/.hermes/hermes-agent/venv/bin/activate
uv pip install 'anthropic[bedrock]' boto3 qrcode 2>&1 | tail -5

echo "=== Hermes install completed ==="
INSTALL_EOF

echo "=== Setup script finished $(date) ==="
