# TFLint configuration. Run with:
#   tflint --init
#   tflint --recursive --config "$(pwd)/.tflint.hcl"

tflint {
  required_version = ">= 0.50"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.48.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # Deliberate: keeps the gate offline, deterministic and credential-free.
  # Validation against the live account is the responsibility of `terraform plan`.
  deep_check = false
}

# Rules outside the "recommended" preset, enabled deliberately.

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

#change to true when the root has its first resource-
rule "terraform_unused_required_providers" {
  enabled = false
}

rule "terraform_standard_module_structure" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "aws_resource_missing_tags" {
  enabled = true
  tags    = ["Project", "Environment", "ManagedBy"]
}
