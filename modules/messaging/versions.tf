terraform {
  # Must match the root module constraints exactly (project standard #7).
  # A child pinned to a different major (the previous "~> 5.0") makes the
  # provider constraint set unsatisfiable and `terraform init` fails.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
