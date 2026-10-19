terraform {
  # Same constraints as the root (standard #7): a different provider
  # constraint here makes `terraform init` unresolvable for the whole
  # configuration.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
