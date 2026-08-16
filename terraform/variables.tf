# ==============================================================================
# variables.tf — Input variables for the root module
#
# Variables with defaults can be left alone for a quick deploy.
# Variables without defaults (ssh_public_key, allowed_ssh_cidr, alert_email)
# MUST be set in terraform.tfvars or via -var flags — Terraform will prompt
# interactively if they're missing.
# ==============================================================================

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  # us-east-1 chosen for broadest service availability and cheapest data transfer.
  # Change to whatever region is closest to you for lower SSH latency.
  default = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS CLI profile Terraform authenticates with. Empty = default credential chain."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Name prefix for all resources — keeps things identifiable in the AWS console"
  type        = string
  default     = "homelab"
}

variable "ssh_public_key" {
  description = "Public SSH key for EC2 access (contents of ~/.ssh/homelab.pub)"
  type        = string
  # No default — you must supply your own key. Never commit private keys.
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH in — should be YOUR IP as x.x.x.x/32"
  type        = string
  # No default on purpose: forces you to think about what IP you're allowing.
  # Use https://checkip.amazonaws.com to find your public IP.
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications (you'll need to confirm the subscription)"
  type        = string
}

variable "repo_url" {
  description = "Public HTTPS clone URL the instance pulls its own config from on first boot"
  type        = string
  default     = "https://github.com/OlajuwonOkeniyi/my-cloud-homelab.git"
}

variable "repo_branch" {
  description = "Branch to clone during bootstrap"
  type        = string
  default     = "main"
}

variable "instance_type" {
  description = "EC2 instance type — check free-tier eligibility for YOUR account"
  type        = string
  # AWS changed the free tier for accounts created on or after 2025-07-15:
  # the 12-month tier was replaced by $100 of credits over 6 months, and the
  # eligible types changed. t2.micro is NOT on the new list; t3.micro is.
  # Confirm for your own account with:
  #   aws ec2 describe-instance-types \
  #     --filters Name=free-tier-eligible,Values=true \
  #     --query "InstanceTypes[*].[InstanceType]" --output text
  #
  # Do NOT use t4g.micro without also changing the AMI filter in
  # modules/compute/main.tf — t4g is ARM (arm64) and the filter matches amd64,
  # so the apply would fail to resolve an image.
  default = "t3.micro"
}
