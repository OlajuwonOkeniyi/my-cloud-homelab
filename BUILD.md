# BUILD.md — Deployment Guide

Step-by-step instructions to deploy this homelab from zero to running.

---

## Prerequisites

Before you start, make sure you have:

- [ ] **AWS Account** with admin access (or at least IAM, EC2, VPC, CloudWatch, SNS permissions)
- [ ] **AWS CLI** configured with credentials (`aws configure` or environment variables)
- [ ] **Terraform** ≥ 1.5.0 installed ([install guide](https://developer.hashicorp.com/terraform/install))
- [ ] **SSH key pair** generated for this project:
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/homelab -C "homelab"
  ```
- [ ] **Your public IP** — you'll need it for the SSH security group:
  ```bash
  curl -s https://checkip.amazonaws.com
  ```

---

## Step 1: Configure Variables

```bash
cd terraform/

# Create your variable file from the example
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
aws_region       = "us-east-1"           # Or your preferred region
project_name     = "homelab"             # Prefix for all AWS resources
instance_type    = "t2.micro"            # Free-tier eligible
ssh_public_key   = "ssh-ed25519 AAAA..."  # Contents of ~/.ssh/homelab.pub
allowed_ssh_cidr = "203.0.113.42/32"     # YOUR IP from the prerequisite step
alert_email      = "you@example.com"     # Where CloudWatch alerts go
```

> **Tip:** Use `/32` for your CIDR — that's "exactly this one IP." If your IP changes often (coffee shop, mobile), you'll need to update this or use a broader range.

---

## Step 2: Initialize and Apply Terraform

```bash
# Download provider plugins and initialize modules
terraform init

# Preview what will be created (review this carefully!)
terraform plan

# Create everything — type "yes" when prompted
terraform apply
```

Terraform will output:
- The instance's public IP
- An SSH command you can copy-paste
- The CloudWatch dashboard URL

**Save these outputs.** You can retrieve them later with `terraform output`.

> **Note:** After apply, check your email. AWS SNS sends a subscription confirmation — you must click the link or you won't receive alerts.

---

## Step 3: SSH In and Run Setup

```bash
# Copy project files to the instance
scp -i ~/.ssh/homelab -r . ubuntu@<INSTANCE_IP>:/tmp/my-cloud-homelab

# SSH into the instance
ssh -i ~/.ssh/homelab ubuntu@<INSTANCE_IP>

# Run the bootstrap script (this takes 2-3 minutes and reboots at the end)
sudo bash /tmp/my-cloud-homelab/scripts/setup.sh
```

The instance will reboot after setup completes. Wait ~30 seconds, then SSH back in.

---

## Step 4: Verify Docker Is Running

After the reboot:

```bash
ssh -i ~/.ssh/homelab ubuntu@<INSTANCE_IP>

# Check the container is running and healthy
docker ps

# Expected output:
# CONTAINER ID   IMAGE           ...   STATUS                    ...
# abc123         homelab-app     ...   Up 2 minutes (healthy)    ...

# Quick smoke test
curl http://localhost:5000/health
# Should return: {"status": "healthy", "timestamp": "..."}

# Check the systemd service
systemctl status homelab
```

If the container isn't running:
```bash
# Check logs for errors
cd /opt/homelab/config
docker compose logs
```

---

## Step 5: Verify Health Check Cron

```bash
# Confirm the cron job is installed
cat /etc/cron.d/homelab-health

# Wait 5 minutes (or run it manually to test)
/usr/local/bin/health_check.sh

# Check the output CSV
cat /opt/homelab/logs/uptime.csv
```

You should see a line like:
```
2026-08-13T15:30:00Z,200,12,true
```

---

## Step 6: Verify CloudWatch Dashboard and Alarms

1. Open the dashboard URL from `terraform output dashboard_url`
   - CPU widget should show data immediately (native EC2 metric)
   - Memory and Disk widgets take ~2 minutes to populate (CloudWatch Agent needs to report)

2. Check alarm state in the AWS Console:
   - Go to **CloudWatch → Alarms**
   - Both alarms (`homelab-cpu-high` and `homelab-status-check-failed`) should be in **OK** state

3. Verify logs are flowing:
   - Go to **CloudWatch → Log Groups**
   - `/homelab/system` should have syslog entries
   - `/homelab/app` should have Docker/gunicorn access logs

> **Troubleshooting:** If memory/disk metrics aren't appearing, SSH in and check the agent:
> ```bash
> sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status
> ```

---

## Step 7: Run Stress Test to Confirm Alerts Work

This is the fun part — intentionally break things to prove the alerts work.

```bash
# SSH into the instance
ssh -i ~/.ssh/homelab ubuntu@<INSTANCE_IP>

# Run the stress test (6 minutes, maxes all CPUs)
./opt/homelab/scripts/stress_test.sh
```

**What to expect:**
- ~1 minute in: CPU metric spikes to 100% on the dashboard
- ~5 minutes in: CloudWatch alarm transitions to **ALARM** state
- ~6 minutes in: Email notification arrives via SNS
- After the test ends: CPU drops, alarm returns to **OK**, you get a recovery email

If the email doesn't arrive, check:
1. Did you confirm the SNS subscription? (Check your spam folder for the confirmation)
2. Is the alarm actually firing? (Check CloudWatch → Alarms → History tab)

---

## Teardown

When you're done (or want to avoid charges):

```bash
cd terraform/

# Destroy everything Terraform created
terraform destroy
```

Type "yes" to confirm. This removes:
- The EC2 instance and its EBS volume
- The VPC, subnet, internet gateway, route table
- The security group, key pair, IAM role
- CloudWatch alarms, log groups, dashboard
- SNS topic and subscription

**Nothing persists after destroy** — the next `terraform apply` starts fresh.

> **Cost note:** If you're on free tier, the only charges should be from CloudWatch custom metrics (~$0.30/month for 2 metrics). Everything else is free-tier eligible for the first 12 months.

---

## Quick Reference

| Task | Command |
|------|---------|
| SSH in | `ssh -i ~/.ssh/homelab ubuntu@$(terraform output -raw instance_public_ip)` |
| View app logs | `docker logs homelab-app --tail 50` |
| Restart the app | `systemctl restart homelab` |
| Check uptime history | `cat /opt/homelab/logs/uptime.csv` |
| Update app code | `cd /opt/homelab && git pull && systemctl restart homelab` |
| Get all Terraform outputs | `terraform output` |
| Check alarm state | `aws cloudwatch describe-alarms --alarm-name-prefix homelab` |
