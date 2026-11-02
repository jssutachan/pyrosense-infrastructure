# Same convention as the other bootstrap stacks. The budget is account-wide,
# so Environment is "shared": importing it replaces the "demo" tag it carried
# in the main configuration (an in-place tag update, nothing recreated).
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "PyroSense"
      Environment = "shared"
      ManagedBy   = "Terraform"
      Stack       = "bootstrap/finops"
    }
  }
}
