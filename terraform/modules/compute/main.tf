# ==============================================================================
# modules/compute/main.tf - EC2 instance and supporting resources
#
# Provisions a single EC2 instance with:
#   - SSH-only security group (locked to your IP)
#   - IAM role for CloudWatch agent (so the instance can push metrics/logs)
#   - Encrypted root volume (because there's no reason not to encrypt at rest)
#   - Auto-resolving Ubuntu 22.04 AMI (always gets the latest patch)
#
# Design decision: No Elastic IP. The public IP changes on stop/start, but for a
# homelab that runs 24/7 this is fine - and it avoids the EIP charge if the
# instance is ever stopped.
# ==============================================================================

# --- AMI Lookup ---
# Dynamically finds the latest Ubuntu 22.04 LTS (Jammy) HVM AMI from Canonical.
# This means `terraform apply` after a few months automatically picks up security patches
# in the base image - no manual AMI ID updates needed.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- SSH Key Pair ---
# Registers your public key with AWS so EC2 can inject it into the instance.
# The private key stays on your machine - never touches AWS.
resource "aws_key_pair" "homelab" {
  key_name   = "${var.project_name}-key"
  public_key = var.ssh_public_key
}

# --- Security Group ---
# Minimal attack surface: SSH inbound from ONE IP, all outbound allowed.
# No HTTP/HTTPS ingress - the app only listens on localhost inside the instance.
# If you want to expose the app publicly later, add port 443 here (with TLS).
resource "aws_security_group" "homelab" {
  name        = "${var.project_name}-sg"
  description = "SSH-only access from my IP"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Outbound: allow everything. The instance needs to reach:
  #   - apt repos for package updates
  #   - Docker Hub for image pulls
  #   - CloudWatch endpoints for metrics/logs
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-sg"
    Project = var.project_name
  }
}

# --- IAM Role for CloudWatch ---
# The EC2 instance needs permission to push custom metrics and logs to CloudWatch.
# This role + instance profile is the AWS-recommended way (vs. hardcoding credentials).
resource "aws_iam_role" "ec2_cloudwatch" {
  name = "${var.project_name}-ec2-role"

  # Trust policy: only EC2 can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# Attach the AWS-managed CloudWatch agent policy - gives write access to
# CloudWatch Metrics, Logs, and read access to SSM Parameter Store
# (which the agent uses for its config in some setups).
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Instance profile is the "container" that lets EC2 instances assume the IAM role.
# It's an AWS quirk - roles can't be directly attached to EC2, only via profiles.
resource "aws_iam_instance_profile" "homelab" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.ec2_cloudwatch.name
}

# --- EC2 Instance ---
resource "aws_instance" "homelab" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.homelab.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.homelab.id]
  iam_instance_profile   = aws_iam_instance_profile.homelab.name

  # --- First-boot bootstrap ---
  # Previously nothing put the project on the instance: there was no user_data,
  # no provisioner and no file copy anywhere in this config, yet the README told
  # you to run `sudo bash /tmp/setup.sh` after SSH-ing in. That file never
  # existed, so the documented path could not work. The instance now fetches its
  # own configuration on first boot and runs the bootstrap unattended.
  #
  # Cloning over HTTPS from a public repo keeps this dependency-free: no S3
  # bucket, no artefact upload, no secret needed on the instance. If the repo is
  # ever made private, replace this with an S3 object read via the instance role.
  #
  # Note: user_data runs ONCE, at first boot. Editing it will not re-run on an
  # existing instance - Terraform shows the diff but leaves the instance alone.
  # Set user_data_replace_on_change = true if you would rather every bootstrap
  # edit rebuild the box; left off here so an innocuous comment change cannot
  # destroy a running homelab.
  user_data = <<-BOOTSTRAP
    #!/usr/bin/env bash
    # -x so every command lands in the log; this is the only record of what
    # happened before you can SSH in.
    set -euxo pipefail

    # No TTY exists during cloud-init. Without this, an apt prompt about a
    # changed config file blocks forever and the instance boots half-built.
    export DEBIAN_FRONTEND=noninteractive

    exec > >(tee -a /var/log/homelab-bootstrap.log) 2>&1
    echo "[bootstrap] started $(date -Is)"

    apt-get update -qq
    apt-get install -y -qq git

    # setup.sh expects the project at this exact path; see its SECTION 4.
    rm -rf /tmp/my-cloud-homelab
    git clone --depth 1 --branch ${var.repo_branch} ${var.repo_url} /tmp/my-cloud-homelab

    echo "[bootstrap] handing over to setup.sh $(date -Is)"
    bash /tmp/my-cloud-homelab/scripts/setup.sh
  BOOTSTRAP

  # --- Burst credit mode ---
  # T3 launches in "unlimited" mode by default; T2 launches in "standard".
  # Moving from t2.micro to t3.micro for free-tier eligibility therefore also
  # changed the billing behaviour: under unlimited, sustained CPU above the
  # baseline over a rolling 24 hours bills surplus credits at a per-vCPU-hour
  # rate instead of throttling. This repository ships scripts/stress_test.sh,
  # which saturates every core for six minutes by design in order to trip the
  # CloudWatch alarm - precisely the workload that generates surplus credits.
  #
  # "standard" restores the t2 behaviour: when credits run out the instance is
  # throttled to its baseline rather than billed. For a homelab whose stated
  # goal is to cost nothing, a slow instance is the correct failure mode and a
  # surprise invoice is not.
  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    volume_size = 20    # 20GB is comfortable for Docker images + logs
    volume_type = "gp3" # gp3 is cheaper than gp2 with better baseline IOPS
    encrypted   = true  # Encryption at rest - no performance penalty on modern instance types
  }

  tags = {
    Name    = "${var.project_name}-server"
    Project = var.project_name
  }
}
