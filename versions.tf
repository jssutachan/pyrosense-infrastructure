# Terraform >= 1.11 is required for native S3 state locking (use_lockfile).
# DynamoDB-based locking is deprecated and intentionally not used here.
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # hashicorp/archive is not declared here: modules/ingest requires it in
  # its own versions.tf, where the Lambda zip is built. Declaring it in the
  # root too would be unused (TFLint terraform_unused_required_providers).



  # Partial backend configuration: account-specific values live in a
  # backend config file (see config/backend.hcl.example) so nothing
  # environment-specific is hardcoded in the codebase.
  #   terraform init -backend-config=config/backend.hcl

  backend "s3" {}

}
