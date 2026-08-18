# ==============================================================================
# provider.tf - Terraform and AWS provider configuration
#
# Pins the Terraform CLI version and the AWS provider version to avoid
# surprise breaking changes. The region is parameterized so the same config
# can deploy to any AWS region without editing this file.
# ==============================================================================

terraform {
  # 1.5+ required for the `check` block and other modern features we may adopt later
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 5.0 allows 5.x patches but won't auto-upgrade to 6.x:
      # major version bumps in the AWS provider frequently break resource schemas
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  # Credentials are never hardcoded here. They are resolved from the named
  # profile below, which `aws configure --profile <name>` writes to
  # ~/.aws/credentials - a file outside this repository.
  #
  # Naming the profile explicitly matters. The AWS CLI can authenticate through
  # sources the Terraform provider cannot read: `aws login` caches short-lived
  # credentials under ~/.aws/login, and the Go SDK behind this provider does not
  # look there. A working `aws sts get-caller-identity` therefore does NOT imply
  # a working `terraform plan`, which fails with the misleading
  # "no EC2 IMDS role found" because it has fallen through to asking the
  # instance metadata service - on your laptop.
  #
  # Leave aws_profile empty to fall back to the default credential chain
  # (environment variables, then the default profile).
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null
}
