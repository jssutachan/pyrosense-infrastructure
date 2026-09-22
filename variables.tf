# ==============================================================================
# Root input contract.
#
# Values arrive from demo.tfvars / prod.tfvars (both gitignored; only the
# .example templates are committed). Per ADR-0002, this contract is the entire
# demo/production delta: the code is written once for production, and only the
# values below change between environments.
#
# Anything identical in both environments belongs as a module default, not here.
# ==============================================================================

# ------------------------------------------------------------------------------
# Deployment context
#
# NOTE: aws_region and environment are consumed by providers.tf (region and
# default_tags), not by main.tf — that is why they look "unused" in this file.
# ------------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment. Drives resource naming and default_tags."
  type        = string

  validation {
    condition     = contains(["demo", "prod"], var.environment)
    error_message = "environment must be either 'demo' or 'prod'."
  }
}

variable "resource_prefix" {
  description = "Base name prefix for all resources, e.g. 'pyrosense'."
  type        = string
  default     = "pyrosense"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.resource_prefix))
    error_message = "resource_prefix must be lowercase alphanumeric and hyphens only."
  }
}

# ------------------------------------------------------------------------------
# FinOps guardrail — consumed by module.budgets (ADR-0003)
# ------------------------------------------------------------------------------

variable "budget_limit_usd" {
  description = "Monthly account cost budget in USD. Set per environment in tfvars."
  type        = number
}

variable "ops_emails" {
  description = "Recipients for budget alerts. At least one required (enforced in the budgets module)."
  type        = list(string)
}

# ------------------------------------------------------------------------------
# Encryption at rest — consumed by module.security (ADR-0010)
# ------------------------------------------------------------------------------

variable "kms_deletion_window_days" {
  description = "Waiting period in days before AWS KMS permanently deletes the pipeline key after deletion is scheduled. Demo uses the 7-day floor for fast teardown; production uses 30 for maximum recovery margin (ADR-0010)."
  type        = number

  # Defaults to the production-safe value: running apply without a -var-file
  # should yield the conservative outcome, never the destructive one.
  default = 30

  # Duplicated in the module on purpose. This copy fails using the name the
  # operator actually typed in their tfvars, and fails before entering the
  # module — a shorter path from error to cause.
  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30 inclusive (AWS KMS limit)."
  }
}
