<div align="center">

# ☤ Hermes Agent — AWS One-Click Deploy

**Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) on AWS EC2 with a single command.**

CloudFormation templates with optional **AWS Bedrock** integration via LiteLLM proxy.

[![Deploy to AWS](https://img.shields.io/badge/Deploy%20to-AWS-FF9900?style=for-the-badge&logo=amazonaws&logoColor=white)](#-quick-start)
[![Hermes Agent](https://img.shields.io/badge/Hermes%20Agent-v0.9.0-blueviolet?style=for-the-badge)](https://github.com/NousResearch/hermes-agent)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

</div>

---

## What This Does

- 🚀 **One command** → Running Hermes Agent instance on AWS
- ☁️ **Bedrock integration** → Use Claude via IAM auth (no API keys needed)
- 🔒 **Secure by default** → Encrypted EBS, restricted SSH, IAM least-privilege
- 📱 **Multi-channel ready** → Pre-configured systemd services for Telegram/Discord/Slack gateway

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  EC2 Instance (Ubuntu 22.04 LTS)                            │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │ Hermes Agent │───▶│ LiteLLM Proxy│───▶│ AWS Bedrock   │  │
│  │  (CLI/Gateway)│    │  :4000       │    │ (Claude, etc) │  │
│  └──────────────┘    └──────────────┘    └───────────────┘  │
│         │                    │                     ▲        │
│         │                    │              IAM Role│        │
│  ┌──────▼──────┐             │              (SigV4) │        │
│  │  Telegram   │             │                     │        │
│  │  Discord    │     OpenAI-compatible       ┌─────┴─────┐  │
│  │  Slack      │         API                 │ IAM Role  │  │
│  └─────────────┘                             │ (Bedrock) │  │
│                                              └───────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

### Prerequisites

- AWS CLI configured (`aws configure`)
- An existing EC2 Key Pair in your target region
- (Optional) [Bedrock model access](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html) enabled for Claude

### Option A: Interactive Deploy Script (Recommended)

```bash
git clone https://github.com/yanghaws/hermes-agent-aws-deploy.git
cd hermes-agent-aws-deploy
chmod +x scripts/*.sh

./scripts/deploy.sh
```

The script will guide you through region, key pair, and SSH settings.

### Option B: One-Liner AWS CLI

```bash
aws cloudformation create-stack \
  --stack-name hermes-agent \
  --template-body file://cloudformation/hermes-agent.yaml \
  --parameters \
    ParameterKey=KeyPairName,ParameterValue=YOUR_KEY_NAME \
    ParameterKey=SSHAllowCIDR,ParameterValue=YOUR_IP/32 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-1

# Wait for completion (~10 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name hermes-agent --region ap-southeast-1

# Get connection info
aws cloudformation describe-stacks \
  --stack-name hermes-agent --region ap-southeast-1 \
  --query 'Stacks[0].Outputs' --output table
```

### Option C: AWS Console

1. Open [CloudFormation Console](https://console.aws.amazon.com/cloudformation)
2. Click **Create stack** → **With new resources**
3. Upload `cloudformation/hermes-agent.yaml`
4. Fill in parameters and deploy

---

## 📋 Configuration Wizard

### After Deployment

SSH into your instance and run the setup wizard:

```bash
# Connect
ssh ubuntu@<PUBLIC_IP>

# Run interactive setup (choose LLM provider, API keys, etc.)
hermes setup

# Start chatting!
hermes
```

### Using Bedrock Models (Pre-configured)

If you deployed with Bedrock enabled (default), Hermes is **already configured** to use Claude via Bedrock. Just start chatting:

```bash
hermes
```

Switch models mid-conversation:

```
/model custom:claude-sonnet    # Claude Sonnet 4
/model custom:claude-opus      # Claude Opus 4
/model custom:claude-haiku     # Claude 3.5 Haiku
```

### Using Other Providers

You can switch to any provider at any time:

```bash
# OpenRouter (200+ models)
hermes config set OPENROUTER_API_KEY sk-or-...
hermes config set model.provider openrouter
hermes config set model.default anthropic/claude-sonnet-4

# Anthropic Direct
hermes config set ANTHROPIC_API_KEY sk-ant-...
hermes config set model.provider anthropic
hermes config set model.default claude-sonnet-4

# Or use the interactive selector
hermes model
```

### Setting Up Messaging Gateway

Connect Hermes to Telegram, Discord, or Slack:

```bash
# Interactive setup
hermes gateway setup

# Enable as system service (auto-start on boot)
sudo systemctl enable --now hermes-gateway

# Check status
sudo systemctl status hermes-gateway
journalctl -u hermes-gateway -f
```

---

## 📁 Templates

| Template | File | Description |
|----------|------|-------------|
| **Full** | [`hermes-agent.yaml`](cloudformation/hermes-agent.yaml) | EC2 + IAM Role (Bedrock) + LiteLLM + systemd services |
| **Minimal** | [`hermes-agent-minimal.yaml`](cloudformation/hermes-agent-minimal.yaml) | Just EC2 + Hermes Agent (no Bedrock, no IAM) |

### Parameters (Full Template)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `KeyPairName` | *(required)* | EC2 Key Pair for SSH |
| `InstanceType` | `t3.medium` | Instance size (t3/m6i/c6i/g5) |
| `VolumeSize` | `30` | EBS volume GB |
| `SSHAllowCIDR` | `0.0.0.0/0` | SSH access CIDR |
| `EnableBedrockAccess` | `true` | Create Bedrock IAM Role |
| `InstallLiteLLM` | `true` | Install LiteLLM proxy |
| `BedrockRegion` | `us-east-1` | Bedrock API region |
| `DefaultBedrockModel` | `claude-sonnet` | Default model alias |
| `HermesAgentBranch` | `main` | Git branch to install |

### Instance Type Guide

| Type | vCPU | RAM | Use Case | Monthly Cost* |
|------|------|-----|----------|---------------|
| `t3.micro` | 2 | 1 GB | Testing only | ~$8 |
| `t3.small` | 2 | 2 GB | Light CLI use | ~$17 |
| `t3.medium` | 2 | 4 GB | **Recommended** — CLI + Gateway | ~$38 |
| `t3.large` | 2 | 8 GB | Heavy tool use + memory | ~$76 |
| `m6i.large` | 2 | 8 GB | Sustained workloads | ~$82 |
| `g5.xlarge` | 4 | 16 GB | Local model inference (GPU) | ~$895 |

*Prices for ap-southeast-1, on-demand. Use Reserved/Spot for savings.

---

## 🔧 Helper Scripts

```bash
# Deploy (interactive)
./scripts/deploy.sh

# Deploy with options
./scripts/deploy.sh --region ap-southeast-1 --key my-key --ssh-cidr 1.2.3.4/32

# Deploy minimal (no Bedrock)
./scripts/deploy.sh --minimal --region us-east-1 --key my-key

# Dry run (print command only)
./scripts/deploy.sh --dry-run

# Check stack status
./scripts/status.sh hermes-agent ap-southeast-1

# Tear down
./scripts/teardown.sh hermes-agent ap-southeast-1
```

---

## 🔐 Security

### What's Secured

- **EBS encryption** — Root volume encrypted at rest
- **Security Group** — Only SSH (port 22) exposed
- **IAM least-privilege** — Bedrock role only has `InvokeModel` + `ListFoundationModels`
- **LiteLLM** — Listens on `localhost:4000` only (not exposed to internet)
- **SSM** — Session Manager enabled for keyless console access

### Recommendations

1. **Restrict SSH CIDR** — Use `YOUR_IP/32` instead of `0.0.0.0/0`
2. **Enable Bedrock Guardrails** — Add content filters in the Bedrock console
3. **Use SSM** — Connect via Session Manager instead of SSH for audit logging

---

## 🛠️ Troubleshooting

### Check Installation Progress

```bash
ssh ubuntu@<IP> "tail -f /var/log/hermes-install.log"
```

### LiteLLM Not Working

```bash
# Check service status
sudo systemctl status litellm
journalctl -u litellm --no-pager -n 50

# Verify Bedrock access
aws bedrock list-foundation-models --region us-east-1 --query 'modelSummaries[?contains(modelId,`claude`)].modelId'

# Test LiteLLM directly
curl http://localhost:4000/v1/models
```

### Bedrock Access Denied

1. Verify the IAM Role has Bedrock permissions:
   ```bash
   aws iam list-attached-role-policies --role-name hermes-agent-role
   ```
2. Ensure model access is enabled in [Bedrock Console](https://console.aws.amazon.com/bedrock/home#/modelaccess)
3. Check the Bedrock region matches where models are enabled

### Hermes Command Not Found

```bash
source ~/.bashrc
# or
export PATH="$HOME/.local/bin:$PATH"
```

---

## 💰 Cost Estimate

| Component | Monthly (ap-southeast-1) |
|-----------|-------------------------|
| EC2 `t3.medium` (on-demand) | ~$38 |
| EBS 30GB gp3 | ~$2.40 |
| Bedrock Claude Sonnet (moderate use) | ~$10–50 |
| **Total** | **~$50–90** |

> 💡 **Cost saving tips:**
> - Use **Spot Instances** for ~60% savings (add `SpotPrice` to the template)
> - Use **Reserved Instances** for ~40% savings on 1-year commitment
> - Set Bedrock **token budgets** in cdk.json or via Bedrock console

---

## 🗑️ Cleanup

```bash
# Delete everything created by this stack
./scripts/teardown.sh hermes-agent ap-southeast-1

# Or via AWS CLI
aws cloudformation delete-stack --stack-name hermes-agent --region ap-southeast-1
```

This removes the EC2 instance, security group, IAM role, and all associated resources.

---

## 📚 References

- [Hermes Agent Documentation](https://hermes-agent.nousresearch.com/docs/)
- [Hermes Agent GitHub](https://github.com/NousResearch/hermes-agent)
- [AWS Bedrock Model Access](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)
- [LiteLLM Bedrock Integration](https://docs.litellm.ai/docs/providers/bedrock)

---

## License

MIT — see [LICENSE](LICENSE).

Built with ☤ [Hermes Agent](https://github.com/NousResearch/hermes-agent) by [Nous Research](https://nousresearch.com).
