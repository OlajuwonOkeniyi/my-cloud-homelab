# ==============================================================================
# main.tf — Root module orchestration
#
# Wires together the three child modules in dependency order:
#   1. networking — VPC, subnet, routing (no dependencies)
#   2. compute   — EC2 instance (depends on networking for subnet/VPC IDs)
#   3. monitoring — CloudWatch alarms & dashboard (depends on compute for instance ID)
#
# Each module is self-contained with its own variables/outputs; this file
# is just the glue that passes values between them.
# ==============================================================================

module "networking" {
  source = "./modules/networking"

  project_name = var.project_name
  aws_region   = var.aws_region
}

module "compute" {
  source = "./modules/compute"

  project_name     = var.project_name
  instance_type    = var.instance_type
  ssh_public_key   = var.ssh_public_key
  allowed_ssh_cidr = var.allowed_ssh_cidr

  # These outputs flow from networking → compute, creating an implicit dependency.
  # Terraform knows to create the VPC/subnet before the EC2 instance.
  subnet_id = module.networking.public_subnet_id
  vpc_id    = module.networking.vpc_id
}

module "monitoring" {
  source = "./modules/monitoring"

  project_name = var.project_name
  instance_id  = module.compute.instance_id
  alert_email  = var.alert_email
  aws_region   = var.aws_region
}
