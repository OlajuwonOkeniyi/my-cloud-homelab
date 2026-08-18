# ==============================================================================
# outputs.tf - Values printed after `terraform apply`
#
# These outputs serve double duty:
#   1. Quick reference after a deploy (IP, SSH command, dashboard link)
#   2. Machine-readable values for scripts: `terraform output -raw instance_public_ip`
# ==============================================================================

output "instance_public_ip" {
  description = "Public IP of the homelab EC2 instance"
  value       = module.compute.public_ip
}

output "instance_id" {
  description = "EC2 instance ID (needed for AWS CLI commands and troubleshooting)"
  value       = module.compute.instance_id
}

output "vpc_id" {
  description = "VPC ID - useful if you want to add more resources to this network later"
  value       = module.networking.vpc_id
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL - bookmark this for at-a-glance monitoring"
  value       = module.monitoring.dashboard_url
}

output "ssh_command" {
  description = "Copy-paste SSH command to connect (adjust key path if yours differs)"
  # No .pem: that extension belongs to keys AWS generates for you. This config
  # imports a key you made yourself, so the private half is whatever ssh-keygen
  # wrote - ~/.ssh/homelab with no extension.
  value = "ssh -i ~/.ssh/homelab ubuntu@${module.compute.public_ip}"
}

output "bootstrap_log_hint" {
  description = "Where to look if the instance comes up but the app does not"
  value       = "sudo cat /var/log/homelab-bootstrap.log   # then /var/log/homelab-setup.log"
}
