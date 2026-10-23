# Bootstrap stack 2/2: the identity the CI/CD pipeline uses in AWS
# (ADR-0023). Applied by the operator, never by the pipeline itself.
#
# Unlike bootstrap/state-backend, this stack keeps its state in the remote
# backend: the bucket already exists, so there is no chicken-and-egg, and a
# second local state file would be one more single copy on one laptop
# (debt #53). It uses its own key, which neither pipeline role can read.
#
#   terraform -chdir=bootstrap/ci-identity init -backend-config=backend.hcl
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {}
}
