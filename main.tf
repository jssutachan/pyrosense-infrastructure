# ==============================================================================
# Root module — composition root.
#
# Wires infrastructure modules together; declares no resources of its own.
# Provider, versions and backend live in providers.tf / versions.tf.
#
# Module order below follows the dependency chain: security produces the key
# ARN that messaging, storage, alerting, iot, ingest and observability will all
# consume as they are added.
# ==============================================================================

locals {
  # Assembled once from resource_prefix + environment, then handed to every
  # module. A naming change touches this line only, and no module can drift
  # out of the shared scheme.
  name_prefix = "${var.resource_prefix}-${var.environment}"
}

# ------------------------------------------------------------------------------
# FinOps guardrail (ADR-0003)
# ------------------------------------------------------------------------------

# Account-wide monthly cost budget. Deployed first because it protects
# everything applied after it: it measures gross consumption
# (include_credit = false), so a runaway resource shows up while free-tier
# credits still cover the bill.
module "budgets" {
  source = "./modules/budgets"

  name_prefix         = local.name_prefix
  limit_usd           = var.budget_limit_usd
  notification_emails = var.ops_emails

  # include_credits, actual_threshold_percents and forecasted_threshold_percent
  # are omitted on purpose — the module's own defaults cover them.
}

# ------------------------------------------------------------------------------
# Encryption at rest (ADR-0010)
# ------------------------------------------------------------------------------

# The single customer-managed KMS key for the whole pipeline. Must exist before
# any module that stores data at rest: messaging, storage, alerting, iot,
# ingest and observability all consume kms_key_arn.
module "security" {
  source = "./modules/security"

  name_prefix          = local.name_prefix
  deletion_window_days = var.kms_deletion_window_days
}
