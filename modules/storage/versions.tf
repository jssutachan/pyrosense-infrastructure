terraform {
  # Must match the root constraint exactly: a child module pinning a
  # different provider major (the AI draft had ~> 5.0) makes
  # `terraform init` unresolvable against the root's ~> 6.0.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
