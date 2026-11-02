terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration: the bucket name carries the account id, so it is
  # passed at init time and never committed (README). The key is outside
  # pyrosense/terraform.tfstate, the only state object the pipeline roles can
  # read or write: the pipeline cannot see or change this stack (ADR-0025).
  backend "s3" {
    key          = "bootstrap/finops/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
