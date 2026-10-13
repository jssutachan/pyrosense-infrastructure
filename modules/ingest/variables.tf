# -----------------------------------------------------------------------------
# Deployment context
# -----------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix assembled once in the root (<resource_prefix>-<environment>). Every resource name in this module derives from it."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,64}$", var.name_prefix))
    error_message = "name_prefix must be 1-64 characters of lowercase letters, digits and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment. Injected as ENVIRONMENT, which the function uses as the value of the EMF Environment dimension."
  type        = string

  # Duplicated from the root on purpose: this copy fails with the module's
  # own name if the module is ever wired from somewhere else.
  validation {
    condition     = contains(["demo", "prod"], var.environment)
    error_message = "environment must be \"demo\" or \"prod\"."
  }
}

variable "source_dir" {
  description = "Directory whose contents become the zip root (src/ingest_lambda). The handler imports its siblings as top-level modules, so the directory itself must not be nested inside the zip."
  type        = string

  validation {
    condition     = fileexists("${var.source_dir}/handler.py") && fileexists("${var.source_dir}/config.py")
    error_message = "source_dir must contain handler.py and config.py at its top level (the zip root)."
  }
}

# -----------------------------------------------------------------------------
# Upstream modules — security, messaging, storage, alerting
# -----------------------------------------------------------------------------

variable "kms_key_arn" {
  description = "Pipeline CMK key ARN (modules/security). Encrypts the log group and the environment variables, and is named in every KMS grant of the execution role."
  type        = string

  # Same literal as modules/alerting (debt #21: align all copies).
  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/(mrk-[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias or a bare key id): IAM policies must name the full key ARN."
  }
}

variable "queue_arn" {
  description = "ARN of the ingest queue (modules/messaging). Event source of the mapping and the only queue the role may consume."
  type        = string
}

variable "queue_message_retention_seconds" {
  description = "Retention of the ingest queue (modules/messaging). One of the two terms of the hot-retention floor: a redriven message restarts this clock."
  type        = number

  validation {
    condition     = var.queue_message_retention_seconds > 0
    error_message = "queue_message_retention_seconds must be positive."
  }
}

variable "dlq_message_retention_seconds" {
  description = "Retention of the DLQ (modules/messaging). The other term of the hot-retention floor: a standard DLQ keeps the original enqueue timestamp, so this is the oldest a message can be when it is redriven."
  type        = number

  validation {
    condition     = var.dlq_message_retention_seconds > 0
    error_message = "dlq_message_retention_seconds must be positive."
  }
}

variable "table_name" {
  description = "Hot-store table name (modules/storage). Injected as TABLE_NAME and used as the DynamoDB encryption-context value."
  type        = string
}

variable "table_arn" {
  description = "Hot-store table ARN (modules/storage). Only resource of the dynamodb:PutItem grant."
  type        = string
}

variable "bucket_id" {
  description = "Cold-store bucket name (modules/storage). Injected as BUCKET_NAME."
  type        = string
}

variable "bucket_arn" {
  description = "Cold-store bucket ARN (modules/storage). Value of the S3 encryption context: with an S3 Bucket Key the context is the bucket ARN, not the object ARN."
  type        = string
}

variable "telemetry_objects_arn" {
  description = "IAM resource for raw telemetry objects, <bucket_arn>/telemetry/* (modules/storage). Consumed as-is so the key prefix is never re-typed here (debt #13)."
  type        = string
}

variable "fire_alerts_topic_arn" {
  description = "Fire-risk alert topic ARN (modules/alerting). Injected as ALERT_TOPIC_ARN and the only resource of the sns:Publish grant."
  type        = string
}

# -----------------------------------------------------------------------------
# Consumer runtime — the same root locals messaging derives its visibility
# timeout from (ADR-0011). Never redefined here.
# -----------------------------------------------------------------------------

variable "timeout_seconds" {
  description = "Function timeout. Comes from local.ingest_lambda_timeout_seconds in the root, the value messaging multiplies by 6 for the visibility timeout."
  type        = number

  validation {
    condition     = var.timeout_seconds >= 1 && var.timeout_seconds <= 900 && floor(var.timeout_seconds) == var.timeout_seconds
    error_message = "timeout_seconds must be an integer between 1 and 900 (Lambda limit)."
  }
}

variable "batching_window_seconds" {
  description = "Batching window of the event source mapping. Comes from local.ingest_batching_window_seconds in the root, the other term of messaging's visibility timeout."
  type        = number

  validation {
    condition     = var.batching_window_seconds >= 0 && var.batching_window_seconds <= 300 && floor(var.batching_window_seconds) == var.batching_window_seconds
    error_message = "batching_window_seconds must be an integer between 0 and 300."
  }
}

# -----------------------------------------------------------------------------
# Detection policy — the "cloud decides" half of the system (ADR-0020).
# Required with no default on purpose: the values are a domain decision held
# in the root, and a module default would hide a fire-detection threshold
# inside infrastructure code. This module validates; it never chooses.
#
# These validations are defense in depth for config.py on develop, which
# parses but does not range-check (debts #15, #23, #24). They do not replace
# fix/config-validation: they only stop Terraform from injecting values the
# code would silently accept.
# -----------------------------------------------------------------------------

variable "smoke_alert_ppm" {
  description = "Smoke concentration (ppm) at or above which a reading is CRITICAL. Injected as SMOKE_ALERT_PPM."
  type        = number

  # Contract v1 accepts smoke_ppm >= 0. A threshold of 0 would make every
  # reading CRITICAL (alert storm); a negative one is the same storm.
  validation {
    condition     = var.smoke_alert_ppm > 0
    error_message = "smoke_alert_ppm must be greater than 0."
  }
}

variable "temp_alert_c" {
  description = "Temperature (°C) that, combined with low humidity, makes a reading ELEVATED. Injected as TEMP_ALERT_C."
  type        = number

  # Contract v1 rejects temp_c outside [-20, 80]. A threshold outside that
  # range can never be crossed, which disables the rule without any error.
  validation {
    condition     = var.temp_alert_c >= -20 && var.temp_alert_c <= 80
    error_message = "temp_alert_c must lie inside the contract range of temp_c, [-20, 80]."
  }
}

variable "rh_alert_pct" {
  description = "Relative humidity (%) that, combined with high temperature, makes a reading ELEVATED. Injected as RH_ALERT_PCT."
  type        = number

  # Same reasoning as temp_alert_c: contract range of rh_pct is [0, 100].
  validation {
    condition     = var.rh_alert_pct >= 0 && var.rh_alert_pct <= 100
    error_message = "rh_alert_pct must lie inside the contract range of rh_pct, [0, 100]."
  }
}

variable "alert_suppression_minutes" {
  description = "Minimum spacing between alerts for the same device. Injected as ALERT_SUPPRESSION_MINUTES."
  type        = number

  # Lower bound: 0 or less disables suppression (alert storm). Upper bound:
  # alerts.py on develop gives the slot a fixed 1-day TTL, so a window longer
  # than 1440 min is deleted by TTL before it closes (debt #15). Revisit the
  # upper bound when fix/config-validation derives the TTL from suppress_until.
  validation {
    condition     = var.alert_suppression_minutes >= 1 && var.alert_suppression_minutes <= 1440 && floor(var.alert_suppression_minutes) == var.alert_suppression_minutes
    error_message = "alert_suppression_minutes must be an integer between 1 and 1440 (the alert slot TTL in alerts.py is 1 day)."
  }
}
