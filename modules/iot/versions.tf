terraform {
  # Must match the root constraint: a child module that pins a different
  # provider series makes `terraform init` unresolvable.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Project standard #7. Note: aws_iot_thing_principal_attachment's
      # thing_principal_type needs provider >= 6.11.0; the root lock file
      # must be at or above it (see README, "Verification").
      version = "~> 6.0"
    }
  }
}
