# ==============================================================================
# provider.tf — Terraform and AWS provider configuration
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
      source  = "hashicorp/aws"
      # ~> 5.0 allows 5.x patches but won't auto-upgrade to 6.x —
      # major version bumps in the AWS provider frequently break resource schemas
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  # Credentials come from environment variables or ~/.aws/credentials —
  # never hardcoded here. Region is the only thing we configure explicitly.
  region = var.aws_region
}
