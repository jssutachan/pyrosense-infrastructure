# ==============================================================================
# Root outputs.
#
# Re-exports the modules' outputs so `terraform output` surfaces them after
# apply, without reading the state file. Two audiences:
#   - the operator, verifying a deployment against the AWS CLI;
#   - a reviewer, seeing that the deployment produced what the code claims.
#
# Grouped by module, in the same order as main.tf.
# ==============================================================================

# ------------------------------------------------------------------------------
# module.budgets (ADR-0003)
# ------------------------------------------------------------------------------

output "budget_arn" {
  description = "ARN of the account monthly cost budget."
  value       = module.budgets.budget_arn
}

output "budget_name" {
  description = "Name of the account-wide monthly budget."
  value       = module.budgets.budget_name
}

# ------------------------------------------------------------------------------
# module.security (ADR-0010)
# ------------------------------------------------------------------------------

output "kms_key_arn" {
  description = "ARN of the pipeline encryption key, consumed by every module that stores data at rest."
  value       = module.security.kms_key_arn
}

output "kms_alias_name" {
  description = "Human-readable alias of the pipeline key, for AWS CLI verification."
  value       = module.security.kms_alias_name
}
