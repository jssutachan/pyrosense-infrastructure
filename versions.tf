# Terraform >= 1.11 is required for native S3 state locking (use_lockfile).
# DynamoDB-based locking is deprecated and intentionally not used here.
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  #Remove the commentary once the Lambda is ready to be ziped.
   # archive = {
    #  source  = "hashicorp/archive"
     # version = "~> 2.4"
    #}
  }

  # Partial backend configuration: account-specific values live in a
  # backend config file (see config/backend.hcl.example) so nothing
  # environment-specific is hardcoded in the codebase.
  #   terraform init -backend-config=config/backend.hcl
  #Remove the comment once the backend is being worked on
 # backend "s3" {}
#
}
