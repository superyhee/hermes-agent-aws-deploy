# ☤ Hermes Agent — AWS One-Click Deploy

Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) on AWS EC2 with **AWS Bedrock** as the LLM backend and **WeChat** as the messaging gateway — in a single command.

## What This Does

```
./deploy-hermes.sh
```

The script provisions a complete Hermes Agent stack on AWS:

| Component   | Detail                                           |
| ----------- | ------------------------------------------------ |
| **Compute** | EC2 Graviton3 ARM64 (configurable instance type) |
| **LLM**     | AWS Bedrock — Claude Sonnet 4 via Converse API   |
| **OS**      | Amazon Linux 2023                                |
| **Gateway** | WeChat messaging with interactive QR login       |
| **Runtime** | Python 3.11, uv, anthropic\[bedrock\], boto3     |

After deployment, you can chat with Hermes directly through WeChat.

## Prerequisites

- **AWS CLI** configured with credentials that have permissions for EC2, IAM, and Bedrock
- **Bedrock model access** enabled for Claude Sonnet 4 in your target region ([request access](https://console.aws.amazon.com/bedrock/home#/modelaccess))
- **WeChat** app on your phone (for QR code login)
- **bash** 4+ and `ssh` available locally

## Quick Start

```bash
git clone https://github.com/<your-org>/hermes-deploy.git
cd hermes-deploy
chmod +x deploy-hermes.sh cleanup-hermes.sh

# Deploy (interactive region & instance type selection)
./deploy-hermes.sh

# When prompted, scan the QR code with WeChat to log in
```

The script walks through 7 steps automatically:

1. **IAM Role & Instance Profile** — creates a role with Bedrock + SSM permissions
2. **SSH Key Pair** — generates an ED25519 key pair
3. **Security Group** — opens port 22 for SSH access
4. **Launch EC2 Instance** — starts the instance with cloud-init provisioning
5. **Wait for Installation** — monitors cloud-init until Hermes is installed
6. **Configure Bedrock** — sets Bedrock as the LLM provider and applies the auxiliary client patch
7. **WeChat Gateway** — interactive QR login, then installs and starts the gateway as a systemd service

### Deploy Demo

```
$ ./deploy-hermes.sh

  Select Region:

    ▸ 1) ap-southeast-1      Singapore
      2) ap-northeast-1      Tokyo
      3) ap-northeast-2      Seoul
      4) ap-south-1          Mumbai
      5) us-east-1           N. Virginia
      6) us-west-2           Oregon
      7) eu-west-1           Ireland
      8) eu-central-1        Frankfurt

  Enter number [default: ap-southeast-1]:

  Select Instance Type:

      1) c7g.medium      1 vCPU,  2 GiB  — Light testing
      2) c7g.large       2 vCPU,  4 GiB  — Small scale
    ▸ 3) c7g.xlarge      4 vCPU,  8 GiB  — Recommended (default)
      4) c7g.2xlarge     8 vCPU, 16 GiB  — High concurrency
      5) m7g.xlarge      4 vCPU, 16 GiB  — Memory intensive
      6) m7g.2xlarge     8 vCPU, 32 GiB  — Memory + high concurrency

  Enter number [default: c7g.xlarge]:

[✓] Region: ap-southeast-1, Instance: c7g.xlarge

══ Pre-flight Checks ══
[✓] AWS Account: 123456789012
[✓] Target Region: ap-southeast-1

══ 1/7 — IAM Role & Instance Profile ══
[✓] Creating IAM role hermes-agent-role...
[✓] IAM policies configured
[✓] Instance profile created (waiting 10s for propagation...)

══ 2/7 — SSH Key Pair ══
[✓] SSH key created: /Users/you/.ssh/hermes-agent-key.pem

══ 3/7 — Security Group ══
[✓] Security group created: sg-0a1b2c3d4e5f

══ 4/7 — Launch EC2 Instance ══
[✓] AMI: ami-0abcdef1234567890
[✓] Instance launched: i-0a1b2c3d4e5f67890
    Waiting for running state... done
[✓] Public IP: 13.212.xxx.xxx

══ 5/7 — Waiting for Hermes Installation ══
    Waiting for SSH (timeout: 600s)......... connected
    Waiting for cloud-init (timeout: 900s)............ done
[✓] Installed: hermes-agent 0.3.x

══ 6/7 — Configuring Hermes for AWS Bedrock ══
[✓] Bedrock provider configured (model: global.anthropic.claude-sonnet-4-6)
Bedrock auxiliary patch applied successfully
[✓] Bedrock auxiliary patch applied
[✓] Sudoers configured for gateway management
[✓] Bedrock verified: model responded 'ok'

══ 7/7 — WeChat Gateway Setup (QR Login) ══

  WeChat QR code will be displayed next
  Scan with WeChat to log in

  Press Enter to start QR login...

  ██████████████████████████████████
  ██████████████████████████████████
  ████ ▄▄▄▄▄ █ ▄▄ █ ▄▄█ ▄▄▄▄▄ ████
  ████ █   █ █▄██ █▄▄ █ █   █ ████
  ████ █▄▄▄█ █ ▄▄▄█▄▄ █ █▄▄▄█ ████
  ████▄▄▄▄▄▄▄█ █▄█ █▄█▄▄▄▄▄▄▄████
  ██████████████████████████████████
  (scan with WeChat)

  WeChat DM policy set to open, user wxid_xxx allowed
● hermes-gateway.service - Hermes Agent Gateway
   Active: active (running)

╔══════════════════════════════════════════════════════════════╗
║           ☤ Hermes Agent Deploy Complete!                    ║
╚══════════════════════════════════════════════════════════════╝

  Instance Info
    Instance ID:  i-0a1b2c3d4e5f67890
    Public IP:    13.212.xxx.xxx
    Region:       ap-southeast-1
    Model:        global.anthropic.claude-sonnet-4-6

  Connect
    ssh -i ~/.ssh/hermes-agent-key.pem ec2-user@13.212.xxx.xxx
    sudo su - hermes
    hermes    # Start interactive terminal

  Gateway Management
    sudo systemctl status hermes-gateway   # Check status
    sudo systemctl restart hermes-gateway   # Restart
    journalctl -u hermes-gateway -f         # Live logs

  WeChat is ready — send a message to Hermes! 💬

[✓] Deploy info saved to ~/.hermes-deploy-info
```

## Usage

### Full Deploy

```bash
./deploy-hermes.sh
```

You'll be prompted to select a region and instance type interactively. Press Enter to accept defaults.

### Skip EC2 Creation (Re-configure Existing Instance)

```bash
./deploy-hermes.sh --skip-ec2
```

Reuses the instance from a previous deploy (reads `~/.hermes-deploy-info`). Useful for re-running the Bedrock configuration or WeChat login steps.

### Cleanup All Resources

```bash
./cleanup-hermes.sh              # Interactive — confirm each step
./cleanup-hermes.sh --force      # Non-interactive — delete everything
./cleanup-hermes.sh --region us-west-2   # Target a specific region
```

Deletes: EC2 instance, SSH key pair, security group, IAM role/profile, and local deploy info.

## Configuration

All settings can be overridden via environment variables or `~/.hermes-deploy.conf`:

| Variable                    | Default                                        | Description                                        |
| --------------------------- | ---------------------------------------------- | -------------------------------------------------- |
| `HERMES_REGION`             | `ap-southeast-1`                               | AWS region (interactive selection if unset)        |
| `HERMES_INSTANCE_TYPE`      | `c7g.xlarge`                                   | EC2 instance type (interactive selection if unset) |
| `HERMES_BEDROCK_MODEL`      | `global.anthropic.claude-sonnet-4-6` | Bedrock model ID                                   |
| `HERMES_VOLUME_SIZE`        | `30`                                           | EBS volume size in GiB                             |
| `HERMES_KEY_NAME`           | `hermes-agent-key`                             | SSH key pair name                                  |
| `HERMES_SG_NAME`            | `hermes-agent-sg`                              | Security group name                                |
| `HERMES_IAM_ROLE`           | `hermes-agent-role`                            | IAM role name                                      |
| `HERMES_IAM_PROFILE`        | `hermes-agent-profile`                         | Instance profile name                              |
| `HERMES_CLOUD_INIT_TIMEOUT` | `900`                                          | Max seconds to wait for cloud-init                 |
| `HERMES_SSH_TIMEOUT`        | `600`                                          | Max seconds to wait for SSH                        |

Example config file (`~/.hermes-deploy.conf`):

```bash
HERMES_REGION=us-west-2
HERMES_INSTANCE_TYPE=c7g.2xlarge
HERMES_VOLUME_SIZE=50
```

### Available Regions

| Region           | Location    |
| ---------------- | ----------- |
| `ap-southeast-1` | Singapore   |
| `ap-northeast-1` | Tokyo       |
| `ap-northeast-2` | Seoul       |
| `ap-south-1`     | Mumbai      |
| `us-east-1`      | N. Virginia |
| `us-west-2`      | Oregon      |
| `eu-west-1`      | Ireland     |
| `eu-central-1`   | Frankfurt   |

### Available Instance Types

| Type          | Specs          | Use Case                  |
| ------------- | -------------- | ------------------------- |
| `c7g.medium`  | 1 vCPU, 2 GiB  | Light testing             |
| `c7g.large`   | 2 vCPU, 4 GiB  | Small scale               |
| `c7g.xlarge`  | 4 vCPU, 8 GiB  | **Recommended**           |
| `c7g.2xlarge` | 8 vCPU, 16 GiB | High concurrency          |
| `m7g.xlarge`  | 4 vCPU, 16 GiB | Memory intensive          |
| `m7g.2xlarge` | 8 vCPU, 32 GiB | Memory + high concurrency |

## Project Structure

```
.
├── deploy-hermes.sh          # Main deployment orchestrator
├── cleanup-hermes.sh         # Resource cleanup script
├── README.md
└── scripts/
    ├── userdata.sh           # EC2 cloud-init script (installs Hermes + deps)
    ├── bedrock-patch.py      # Patches Hermes to support Bedrock Converse API
    └── gateway-setup.sh      # Post-QR-login gateway configuration
```

Scripts in `scripts/` are uploaded to the EC2 instance via `scp` and executed remotely. They can also be run independently for debugging.

## Post-Deploy

### Connect to the Instance

```bash
ssh -i ~/.ssh/hermes-agent-key.pem ec2-user@<PUBLIC_IP>
sudo su - hermes
hermes    # Start interactive terminal
```

### Manage the Gateway

```bash
sudo systemctl status hermes-gateway    # Check status
sudo systemctl restart hermes-gateway   # Restart
journalctl -u hermes-gateway -f         # Live logs
```

### Re-login to WeChat

If the WeChat session expires, re-run the QR login:

```bash
./deploy-hermes.sh --skip-ec2
```

## How the Bedrock Patch Works

Hermes Agent natively supports OpenAI-compatible APIs. The `bedrock-patch.py` script adds a Bedrock adapter by patching `auxiliary_client.py` to:

1. Add `BedrockAuxiliaryClient` — wraps the Bedrock Converse API behind an OpenAI-compatible interface
2. Register the async variant in `_to_async_client()`
3. Handle `aws_sdk` auth type in `resolve_provider_client()`

The patch is idempotent — running it multiple times is safe. It will skip if already applied and report clear errors if the Hermes version is incompatible.

## Security Notes

- The security group opens **port 22 to 0.0.0.0/0** by default. For production use, restrict the SSH source IP in the AWS console or override `HERMES_SG_NAME` with a pre-configured security group.
- The IAM role grants Bedrock invoke permissions with `Resource: *`. Consider restricting to specific model ARNs for tighter access control.
- IMDSv2 is enforced (`HttpTokens=required`) and EBS volumes are encrypted by default.

## Troubleshooting

| Issue                              | Solution                                                                                                                          |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Bedrock test fails                 | Ensure model access is enabled in the [Bedrock console](https://console.aws.amazon.com/bedrock/home#/modelaccess) for your region |
| SSH timeout                        | Check security group rules and that the instance has a public IP                                                                  |
| cloud-init error                   | SSH in and check `/var/log/hermes-setup.log`                                                                                      |
| WeChat QR not showing              | Ensure your terminal supports the QR display; try a larger terminal window                                                        |
| Gateway shows "No user allowlists" | Re-run `./deploy-hermes.sh --skip-ec2` to reconfigure the gateway                                                                 |

## License

MIT
