terraform {
  # Same floor as the root (S3 native state locking) and every other module
  # (standard #7). A different constraint here makes `terraform init`
  # unresolvable for the whole configuration.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    # Packages src/ingest_lambda into the deployment zip. 2.8 is the series
    # verified on 2026-10-06 (2.8.1); its excludes accept glob patterns, which
    # the __pycache__ exclusion below relies on.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
    }
  }
}
