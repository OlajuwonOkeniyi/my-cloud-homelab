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

variable "instance_type" {
  description = "EC2 instance type — t2.micro is free-tier eligible"
  type        = string
  # t2.micro: 1 vCPU, 1GB RAM. Enough for a containerized Flask app.
  # Bump to t3.small if you start running multiple containers.
  default = "t2.micro"
}
