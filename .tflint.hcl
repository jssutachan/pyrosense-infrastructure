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

rule "terraform_unused_required_providers" {
  enabled = true
}

rule "terraform_standard_module_structure" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Disabled: with a root-level default_tags strategy, this rule can't see the
# tags across the module boundary — it lints each module in isolation, where
# no provider (hence no default_tags) exists, and reports a false positive on
# every resource. Replaced by aws_provider_missing_default_tags below, which
# verifies the tag contract where it actually lives: the provider. See ADR-000X.
rule "aws_resource_missing_tags" {
  enabled = false
  tags    = ["Project", "Environment", "ManagedBy"]
}

# Enforces the real tag contract: the aws provider must declare default_tags
# with these keys. Runs where the provider block lives (root + bootstrap),
# which is exactly where tflint can read it.
rule "aws_provider_missing_default_tags" {
  enabled = true
  tags    = ["Project", "Environment", "ManagedBy"]
}
