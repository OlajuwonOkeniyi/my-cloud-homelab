#!/usr/bin/env bash
# ==============================================================================
# setup.sh — One-shot bootstrap for a fresh EC2 instance
#
# Run this ONCE after first SSH into the new instance:
#     sudo bash setup.sh
#
# What it does (in order):
#   1. Updates all system packages
#   2. Installs Docker CE + Compose plugin from Docker's official repo
#   3. Installs and configures the CloudWatch Agent for custom metrics/logs
#   4. Deploys the homelab app via systemd + Docker Compose
#   5. Sets up the health check cron job
#   6. Applies basic SSH hardening (key-only auth, no passwords)
#   7. Enables unattended security updates
#   8. Reboots to apply kernel updates and group changes
#
# Prerequisites:
#   - Project files must be in /tmp/my-cloud-homelab (scp them before running)
#     OR clone the repo directly to /opt/homelab
#   - Instance must have the IAM role attached (done by Terraform)
#
# This script is idempotent-ish: running it twice won't break anything,
# but it's designed as a one-time bootstrap, not a config management tool.
# ==============================================================================
set -euo pipefail

HOMELAB_DIR="/opt/homelab"
LOG_FILE="/var/log/homelab-setup.log"

# Helper: timestamped logging to both console and file
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "Starting homelab setup..."

# =============================================================================
# SECTION 1: System Updates
# =============================================================================
# -qq = quiet output (less noise in logs). Upgrade everything to latest patches.
log "Updating packages..."
apt-get update -qq
apt-get upgrade -y -qq

# =============================================================================
# SECTION 2: Docker Installation
# =============================================================================
# Using Docker's official apt repo (not Ubuntu's outdated docker.io package).
# This gives us Docker CE + the Compose V2 plugin (docker compose, not docker-compose).
log "Installing Docker..."
apt-get install -y -qq ca-certificates curl gnupg

# Set up Docker's GPG key for package verification
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker's apt repository — architecture-aware for ARM compatibility if needed
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Let the ubuntu user run docker without sudo (takes effect after reboot/re-login)
usermod -aG docker ubuntu

# =============================================================================
# SECTION 3: CloudWatch Agent
# =============================================================================
# The agent pushes memory/disk metrics and container logs to CloudWatch.
# EC2's built-in monitoring only covers CPU and network — memory and disk
# require the agent.
log "Installing CloudWatch agent..."
wget -q https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E amazon-cloudwatch-agent.deb
rm -f amazon-cloudwatch-agent.deb

# Agent configuration — defines which metrics to collect and which logs to ship.
# Metrics: memory usage %, disk usage % (root partition)
# Logs: /var/log/syslog → /homelab/system, Docker container logs → /homelab/app
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    },
    "metrics_collected": {
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["disk_used_percent"],
        "resources": ["/"],
        "metrics_collection_interval": 60
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/syslog",
            "log_group_name": "/homelab/system",
            "log_stream_name": "{instance_id}/syslog",
            "retention_in_days": 14
          },
          {
            "file_path": "/var/lib/docker/containers/**/*.log",
            "log_group_name": "/homelab/app",
            "log_stream_name": "{instance_id}/docker",
            "retention_in_days": 14
          }
        ]
      }
    }
  }
}
EOF

# Start the agent with our config. -m ec2 tells it to use the instance's IAM role.
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 \
    -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# =============================================================================
# SECTION 4: Application Deployment
# =============================================================================
# Copy project files into /opt/homelab — the canonical location on the instance.
# If you prefer git pull, clone directly to $HOMELAB_DIR instead.
log "Setting up application..."
mkdir -p "$HOMELAB_DIR"
cp -r /tmp/my-cloud-homelab/* "$HOMELAB_DIR/" 2>/dev/null || {
    log "Note: Copy project files to /tmp/my-cloud-homelab before running, or clone the repo to $HOMELAB_DIR"
}

# Install the systemd service that manages the Docker Compose lifecycle
cp "$HOMELAB_DIR/config/homelab.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable homelab.service   # Start on boot
systemctl start homelab.service    # Start now

# =============================================================================
# SECTION 5: Health Check Cron
# =============================================================================
# Runs every 5 minutes, logs uptime data to CSV for trend analysis.
# Separate from Docker's built-in healthcheck — this gives us a historical record.
log "Setting up health check cron..."
mkdir -p "$HOMELAB_DIR/logs"
cp "$HOMELAB_DIR/scripts/health_check.sh" /usr/local/bin/
chmod +x /usr/local/bin/health_check.sh
echo "*/5 * * * * root /usr/local/bin/health_check.sh" > /etc/cron.d/homelab-health

# =============================================================================
# SECTION 6: Security Hardening
# =============================================================================
# Minimal but meaningful hardening for an internet-facing instance.
log "Applying basic hardening..."

# Force key-only SSH — disable password authentication entirely.
# The Terraform-deployed key pair is the only way in.
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

# Unattended upgrades: automatically applies security patches daily.
# Won't auto-reboot, but keeps the instance patched between manual maintenance windows.
apt-get install -y -qq unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades

# =============================================================================
# DONE — Reboot to apply everything cleanly
# =============================================================================
# Reboot ensures: kernel updates take effect, docker group membership applies
# to the ubuntu user, and all services start in their final boot configuration.
log "Setup complete! Rebooting in 5 seconds to apply all changes..."
sleep 5
reboot
