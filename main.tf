# Root module — composition root.
# Wires infrastructure modules together; declares no resources of its own.
# Provider, versions and backend live in providers.tf / versions.tf.

locals {
  # Assembled once from resource_prefix + environment, then handed to every
  # module. A naming change touches this line only, and no module can drift
  # out of the shared scheme.
  name_prefix = "${var.resource_prefix}-${var.environment}"
}

module "budgets" {
  source = "./modules/budgets"

  name_prefix         = local.name_prefix
  limit_usd           = var.budget_limit_usd
  notification_emails = var.ops_emails

  # include_credits, actual_threshold_percents and forecasted_threshold_percent
  # are omitted on purpose — the module's own defaults cover them.
}
