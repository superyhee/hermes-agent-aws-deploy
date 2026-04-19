#!/bin/bash
# =============================================================================
# Hermes Gateway Post-Setup Script
# =============================================================================
# Runs on the EC2 instance (as ec2-user via ssh_cmd) after WeChat QR login.
# Installs the systemd service, configures DM policy, and starts the gateway.
#
# Environment variables (passed by deploy-hermes.sh):
#   HERMES_REGION  — AWS region for Bedrock
# =============================================================================

set -euo pipefail

REGION="${HERMES_REGION:?HERMES_REGION must be set}"

# ---------------------------------------------------------------------------
# Install systemd service
# ---------------------------------------------------------------------------
sudo /home/hermes/.local/bin/hermes gateway install --system --run-as-user hermes 2>&1 || true

# Add AWS region to systemd service
sudo sed -i '/^Environment="HERMES_HOME=/a Environment="AWS_DEFAULT_REGION='"${REGION}"'"\nEnvironment="AWS_REGION='"${REGION}"'"' \
    /etc/systemd/system/hermes-gateway.service

# ---------------------------------------------------------------------------
# Auto-approve pairing & open DM access
# ---------------------------------------------------------------------------
# The default DM_POLICY=pairing requires a manual "hermes pairing approve" step.
# Auto-approve the first paired user and switch to open policy so messages
# flow immediately after QR scan.

HOME_USER=$(sudo grep '^WEIXIN_HOME_CHANNEL=' /home/hermes/.hermes/.env 2>/dev/null | tail -1 | cut -d= -f2)
OPENID=$(echo "$HOME_USER" | sed 's/@im.wechat//')

# Always set the global gateway allow-all flag (covers newer Hermes versions)
sudo grep -q '^GATEWAY_ALLOW_ALL_USERS=' /home/hermes/.hermes/.env 2>/dev/null \
    && sudo sed -i 's|^GATEWAY_ALLOW_ALL_USERS=.*|GATEWAY_ALLOW_ALL_USERS=true|' /home/hermes/.hermes/.env \
    || echo 'GATEWAY_ALLOW_ALL_USERS=true' | sudo tee -a /home/hermes/.hermes/.env >/dev/null

if [ -n "$OPENID" ]; then
    # Approve any pending pairing for this user
    sudo su - hermes -c "
        export PATH=\$HOME/.local/bin:\$PATH
        hermes pairing list 2>/dev/null | grep -q 'No pending' || \
        hermes pairing approve weixin \$(hermes pairing list 2>/dev/null | grep weixin | awk '{print \$NF}') 2>/dev/null || true
    " 2>/dev/null || true

    # Set DM policy to open + allow the QR-scanned user
    sudo sed -i 's|^WEIXIN_DM_POLICY=pairing|WEIXIN_DM_POLICY=open|' /home/hermes/.hermes/.env
    sudo sed -i 's|^WEIXIN_ALLOW_ALL_USERS=false|WEIXIN_ALLOW_ALL_USERS=true|' /home/hermes/.hermes/.env
    sudo sed -i "s|^WEIXIN_ALLOWED_USERS=\$|WEIXIN_ALLOWED_USERS=${OPENID}|" /home/hermes/.hermes/.env
    echo "  WeChat DM policy set to open, user ${OPENID} allowed"
else
    echo "  Warning: could not extract WEIXIN_HOME_CHANNEL, relying on GATEWAY_ALLOW_ALL_USERS=true"
fi

# ---------------------------------------------------------------------------
# Reload and start
# ---------------------------------------------------------------------------
sudo systemctl daemon-reload
sudo systemctl restart hermes-gateway

sleep 3
sudo systemctl status hermes-gateway --no-pager
