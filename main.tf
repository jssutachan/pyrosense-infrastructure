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

  # Ingest Lambda runtime settings, shared by two modules: messaging derives
  # the queue visibility timeout from them (6 x timeout + batching window),
  # and ingest will configure the function and its event source mapping with
  # the same values. One definition here means the queue and its consumer
  # cannot disagree. Locals, not variables: they are identical in demo and
  # prod (ADR-0002), and variables.tf holds only the environment delta.
  #
  # 30 s is provisional: no Duration data exists yet. Revisit once
  # module.ingest runs, against the measured p99 Duration and the alert
  # latency trade-off (each transient retry waits one visibility timeout).
  ingest_lambda_timeout_seconds = 30

  # 0 = invoke as soon as messages are available (lowest alert latency).
  # Constraint for module.ingest: batch sizes above 10 require a batching
  # window of at least 1 s, so batch_size must stay <= 10 while this is 0.
  ingest_batching_window_seconds = 0
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

# ------------------------------------------------------------------------------
# Ingest buffer: IoT Core -> SQS (+DLQ) -> ingest Lambda (ADR-0008, ADR-0010)
# ------------------------------------------------------------------------------

# Standard SQS queue and its dead-letter queue, both SSE-KMS with the pipeline
# key. The reference to module.security.kms_key_arn is the only ordering this
# module needs: Terraform creates the key first because the queues read its
# ARN. No module-level depends_on on purpose: HashiCorp documents it as a last
# resort that, especially on modules, yields more conservative plans than an
# expression reference, which already carries the ordering.
module "messaging" {
  source = "./modules/messaging"

  name_prefix = local.name_prefix
  kms_key_arn = module.security.kms_key_arn

  consumer_timeout_seconds         = local.ingest_lambda_timeout_seconds
  consumer_batching_window_seconds = local.ingest_batching_window_seconds
}
