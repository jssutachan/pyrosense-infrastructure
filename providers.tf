provider "aws" {
  region = var.aws_region

  # Every resource created by this provider is born tagged.
  # Cost attribution and traceability are non-negotiable from day one.
  default_tags {
    tags = {
      Project     = "PyroSense"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
