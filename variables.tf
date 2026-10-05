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
# NOTE: aws_region is consumed only by providers.tf (region). environment is
# consumed three times: providers.tf (default_tags), main.tf (local.name_prefix)
# and the cross-variable validation on allow_data_destruction below.
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

# ------------------------------------------------------------------------------
# Notification recipients — consumed by module.budgets and module.alerting
# (ADR-0003, ADR-0014)
#
# Maps of { label = email }, not lists of addresses. Terraform always discloses
# for_each keys in resource addresses, so alerting keys its subscriptions by
# label: "pyrosense-demo-fire-alerts" subscriptions read
# aws_sns_topic_subscription.fire_alerts["duty-desk"], never an address. Labels
# also keep the keys stable — removing one recipient destroys exactly that one
# subscription instead of shifting the rest.
#
# Both are sensitive and neither has a default: an address is PII (standard
# #11), and there is no safe fallback recipient. Running plan without a
# -var-file fails, which is the conservative outcome. Validated in
# module.alerting (shape, label format, address format, no duplicates).
# ------------------------------------------------------------------------------

variable "ops_recipients" {
  description = "Platform operators, as { label = email }. Receive budget notifications (module.budgets) and CloudWatch alarm notifications (module.alerting ops topic). One intent, one input: these are the people who run the platform."
  type        = map(string)
  sensitive   = true
}

variable "fire_alert_recipients" {
  description = "Fire-risk alert responders, as { label = email }. A different audience from ops_recipients: in production these are duty desks at the responding institutions, not the platform team. Receive the CRITICAL alerts published by the ingest Lambda."
  type        = map(string)
  sensitive   = true
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

# ------------------------------------------------------------------------------
# Data lifecycle — consumed by module.storage (ADR-0013)
# ------------------------------------------------------------------------------

variable "allow_data_destruction" {
  description = "Whether `terraform destroy` may delete stored data: true disables DynamoDB deletion protection and enables S3 force_destroy. Demo only (apply -> evidence -> destroy cycle, ADR-0002); must be false in production (ADR-0013)."
  type        = bool

  # Defaults to the production-safe value, same rule as
  # kms_deletion_window_days: an apply without a -var-file must never
  # produce a data store that destroy can wipe.
  default = false

  # Cross-variable rule (Terraform >= 1.9, and required_version is 1.11):
  # the one combination that must never exist. A copy-paste slip in
  # prod.tfvars fails at plan instead of at the first destroy.
  validation {
    condition     = !(var.environment == "prod" && var.allow_data_destruction)
    error_message = "allow_data_destruction must be false when environment is 'prod'."
  }
}
