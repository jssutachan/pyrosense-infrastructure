provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "PyroSense"
      Environment = "shared"
      ManagedBy   = "Terraform"
      Stack       = "bootstrap/ci-identity"
    }
  }
}
