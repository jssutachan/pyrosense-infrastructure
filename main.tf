# ==============================================================================
# Root module — composition root.
#
# Wires infrastructure modules together; declares no resources of its own.
# Provider, versions and backend live in providers.tf / versions.tf.
#
# Module order below follows the dependency chain: security produces the key
# ARN that messaging, storage, alerting, iot and ingest consume; observability
# comes last because it reads the names every other module exports, and it
# needs no key (its alarms are authorized by the key policy, not by an input).
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
  # 30 s, kept after measurement (ADR-0021 D5): the 2026-10-07 demo cycle
  # recorded 21 invocations with Duration p50 52 ms, p99 1711 ms and maximum
  # 1715 ms, under 6 % of the timeout. Not lowered: the visibility timeout and
  # the time to DLQ derive from it (ADR-0011), and 21 demo samples do not
  # justify retuning the retry contract. Revisit with production-scale Duration.
  ingest_lambda_timeout_seconds = 30

  # 0 = invoke as soon as messages are available (lowest alert latency).
  # Constraint for module.ingest: batch sizes above 10 require a batching
  # window of at least 1 s, so batch_size must stay <= 10 while this is 0.
  ingest_batching_window_seconds = 0

  # Fire-detection policy for module.ingest: the "cloud decides" half of the
  # system (ADR-0002, ADR-0005). Locals, not variables: a fire threshold is the
  # same in demo and prod, and variables.tf holds only the environment delta.
  # Kept here, not as module defaults, so the policy is read next to the rest
  # of the design constants instead of being hidden in infrastructure code.
  # module.ingest validates each one against the contract-v1 ranges.
  #
  # Provisional placeholders pending sign-off by the domain owner (ADR-0020):
  # the values the test suite has always exercised. Not tuned for real fires;
  # alerting is non-life-safety in v1.0 (ADR-0015). Change here + ADR-0020.
  ingest_smoke_alert_ppm           = 5.0  # CRITICAL at or above: the only rule that alerts
  ingest_temp_alert_c              = 30.0 # ELEVATED (with rh) at or above: adds a reason, never alerts in v1
  ingest_rh_alert_pct              = 25.0 # ELEVATED (with temp) at or below
  ingest_alert_suppression_minutes = 30   # one email per device per half hour; 1-1440 because the slot TTL is 1 day (debt #15)

  # Operations policy for module.observability (ADR-0021 D2): minutes without
  # a single message matched by the telemetry rule before the fleet is
  # declared silent. A local, not a variable: the window is the same in demo
  # and prod. In demo the alarm fires after every test burst, and those emails
  # are the end-to-end proof that alarms reach the encrypted ops topic.
  # Provisional, like the detection policy above: set it from the real sensor
  # reporting cadence once a domain owner exists. A multiple of 5 between 5
  # and 1440 (validated in the module).
  observability_telemetry_silence_minutes = 10

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
  notification_emails = values(var.ops_recipients)

  # include_credits, actual_threshold_percents and forecasted_threshold_percent
  # are omitted on purpose — the module's own defaults cover them.
}

# ------------------------------------------------------------------------------
# Encryption at rest (ADR-0010)
# ------------------------------------------------------------------------------

# The single customer-managed KMS key for the whole pipeline. Must exist before
# any module that stores data at rest: messaging, storage, alerting, iot and
# ingest consume kms_key_arn. Observability does not: CloudWatch alarms reach
# the encrypted ops topic as a service principal authorized in this key's
# policy (AllowCloudWatchAlarms), not through an input.
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


# ------------------------------------------------------------------------------
# Hot/cold persistence: DynamoDB + S3 (ADR-0008, ADR-0013)
# ------------------------------------------------------------------------------

# DynamoDB single-table (dedup guard + alert-suppression slot) and the raw S3
# archive. The key schema mirrors persistence.py, alerts.py and cold_store.py
# exactly; the module only declares it. Ordered after security by the
# kms_key_arn reference, like messaging.
#
# allow_data_destruction is one intent driving two mechanisms (DynamoDB
# deletion protection and S3 force_destroy), so an environment can never be
# half-protected.
module "storage" {
  source = "./modules/storage"

  name_prefix = local.name_prefix
  kms_key_arn = module.security.kms_key_arn

  allow_data_destruction = var.allow_data_destruction
}

# ------------------------------------------------------------------------------
# Notification layer: SNS fire-risk alerts + operational alarms (ADR-0014, ADR-0015)
# ------------------------------------------------------------------------------

# Two topics with two different publishers. The fire topic is published by the
# ingest Lambda through its IAM role; the ops topic by CloudWatch Alarms as a
# service principal, which has no IAM identity and can only be authorized in
# the topic policy. That difference is why the module writes two topics out
# instead of taking a flag (ADR-0014).
#
# Ordered after security by the kms_key_arn reference, like messaging and
# storage. Email subscriptions stay pending until each recipient confirms;
# Terraform cannot confirm them, so pending subscriptions after apply are
# expected and not a failed apply (ADR-0015).
module "alerting" {
  source = "./modules/alerting"

  name_prefix = local.name_prefix
  kms_key_arn = module.security.kms_key_arn

  fire_alert_recipients = var.fire_alert_recipients
  ops_recipients        = var.ops_recipients
}

# ------------------------------------------------------------------------------
# System boundary: AWS IoT Core identity + topic rule -> SQS (ADR-0016, ADR-0017, ADR-0018)
# ------------------------------------------------------------------------------

# The only compute in the pipeline. It consumes every upstream module and is
# consumed by none except observability. Division of labour on failure
# (ADR-0011): the handler decides WHICH messages failed and reports them in
# batchItemFailures; the queue decides WHEN to retry them (visibility timeout)
# and WHEN to give up (maxReceiveCount -> DLQ). That is why timeout and
# batching window come from the same two locals messaging derives the
# visibility timeout from.
#
# topic_base reuses resource_prefix: the project identifier names the AWS
# resources and roots the MQTT topic tree, so the two namespaces cannot drift
# apart. The {env} topic level comes from the same environment that builds
# name_prefix: naming, not a hidden demo/prod delta.
#
# Only the CSR crosses into Terraform. The private key is generated on the
# operator's machine and is never read here (ADR-0017). file() needs the CSR to
# exist before the run, so a fresh machine fails at plan until the key step of
# the modules/iot README runbook is done.
module "iot" {
  source = "./modules/iot"

  name_prefix = local.name_prefix
  topic_base  = var.resource_prefix
  environment = var.environment

  queue_arn   = module.messaging.queue_arn
  queue_url   = module.messaging.queue_url
  kms_key_arn = module.security.kms_key_arn

  fleet_client_csr_pem = file(pathexpand(var.iot_fleet_client_csr_path))
}

# ------------------------------------------------------------------------------
# Consumer: SQS -> ingest Lambda -> DynamoDB + S3 + SNS (ADR-0008, ADR-0011, ADR-0019, ADR-0020)
# ------------------------------------------------------------------------------

# The only compute in the pipeline. It consumes every upstream module and is
# consumed by none except observability. Retries belong to the queue: a failed
# message reappears after messaging's visibility timeout and moves to the DLQ
# after maxReceiveCount, which is why timeout and batching window come from the
# same two locals messaging derives that timeout from.
#
# HOT_RETENTION_DAYS is derived inside the module from messaging's two
# retentions: a redriven duplicate must still find its hot item, or the
# conditional write accepts it as new and the alert fires again (ADR-0019 D6).
#
# No dependency on module.iot on purpose: the coupling is the queue and the
# message body (byte-for-byte device JSON), not any output.
module "ingest" {
  source = "./modules/ingest"

  name_prefix = local.name_prefix
  environment = var.environment
  source_dir  = "${path.module}/src/ingest_lambda"

  kms_key_arn = module.security.kms_key_arn

  queue_arn                       = module.messaging.queue_arn
  queue_message_retention_seconds = module.messaging.message_retention_seconds
  dlq_message_retention_seconds   = module.messaging.dlq_message_retention_seconds

  table_name            = module.storage.table_name
  table_arn             = module.storage.table_arn
  bucket_id             = module.storage.bucket_id
  bucket_arn            = module.storage.bucket_arn
  telemetry_objects_arn = module.storage.telemetry_objects_arn

  fire_alerts_topic_arn = module.alerting.fire_alerts_topic_arn

  timeout_seconds         = local.ingest_lambda_timeout_seconds
  batching_window_seconds = local.ingest_batching_window_seconds

  smoke_alert_ppm           = local.ingest_smoke_alert_ppm
  temp_alert_c              = local.ingest_temp_alert_c
  rh_alert_pct              = local.ingest_rh_alert_pct
  alert_suppression_minutes = local.ingest_alert_suppression_minutes
}

# ------------------------------------------------------------------------------
# Observability: CloudWatch alarms -> SNS ops topic, log metric filters, dashboard (ADR-0021)
# ------------------------------------------------------------------------------

# Answers "who finds out if this fails?" for every boundary of the pipeline:
# ten alarms, each owning one fault at the layer where it first becomes
# visible, all notifying the ops topic on ALARM and on OK. It reads only names
# and ARNs the other modules already export, creates no data path and takes no
# KMS input (see module.security above).
#
# Thresholds are derived, not typed: the queue-age alarm fires above two of
# messaging's visibility timeouts, and the Duration widget draws the same
# timeout local the function uses, so retuning the consumer moves the alarms
# with it. The silence window is policy and lives with the design constants
# in the locals block.
module "observability" {
  source = "./modules/observability"

  name_prefix = local.name_prefix
  environment = var.environment

  queue_name                       = module.messaging.queue_name
  dlq_name                         = module.messaging.dlq_name
  queue_visibility_timeout_seconds = module.messaging.visibility_timeout_seconds

  function_name            = module.ingest.function_name
  function_timeout_seconds = local.ingest_lambda_timeout_seconds
  ingest_log_group_name    = module.ingest.log_group_name
  metrics_namespace        = module.ingest.metrics_namespace

  topic_rule_name           = module.iot.topic_rule_name
  rule_error_log_group_name = module.iot.rule_error_log_group_name

  fire_alerts_topic_name = module.alerting.fire_alerts_topic_name
  ops_topic_arn          = module.alerting.ops_topic_arn

  telemetry_silence_minutes = local.observability_telemetry_silence_minutes
}

locals {
  zz_bad   =    1
}
