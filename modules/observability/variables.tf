# Every input is a name, an ARN or a value another module already owns. The
# module computes thresholds from them (review criterion #7) and holds only
# one policy value of its own: the silence window (ADR-0021 D2).

variable "name_prefix" {
  description = "Prefix for every alarm, metric filter and the dashboard, e.g. pyrosense-demo. Built by the root (local.name_prefix); this module never assembles it."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,64}$", var.name_prefix))
    error_message = "name_prefix must be 1-64 lowercase letters, digits or hyphens."
  }
}

variable "environment" {
  description = "Deployment environment. Value of the Environment dimension of the ingest EMF metrics, and part of the namespace of the log-derived metrics. A typo here gives empty graphs and alarms that never fire, with no error, hence the validation."
  type        = string

  validation {
    condition     = contains(["demo", "prod"], var.environment)
    error_message = "environment must be \"demo\" or \"prod\"."
  }
}

# ---- From modules/messaging --------------------------------------------------

variable "queue_name" {
  description = "Ingest queue name (modules/messaging output queue_name). QueueName dimension of the queue-age alarm and the dashboard."
  type        = string

  validation {
    condition     = length(trimspace(var.queue_name)) > 0
    error_message = "queue_name must not be empty."
  }
}

variable "dlq_name" {
  description = "Dead-letter queue name (modules/messaging output dlq_name). QueueName dimension of the DLQ alarm."
  type        = string

  validation {
    condition     = length(trimspace(var.dlq_name)) > 0
    error_message = "dlq_name must not be empty."
  }
}

variable "queue_visibility_timeout_seconds" {
  description = "Visibility timeout of the ingest queue (modules/messaging output visibility_timeout_seconds). The queue-age threshold is derived from it (2 x VT), so retuning the consumer timeout moves the alarm with it."
  type        = number

  # SQS range: 0-43200 s. 0 would make the derived threshold 0 and the alarm
  # fire on any non-empty queue, so the floor here is 1.
  validation {
    condition     = var.queue_visibility_timeout_seconds >= 1 && var.queue_visibility_timeout_seconds <= 43200 && floor(var.queue_visibility_timeout_seconds) == var.queue_visibility_timeout_seconds
    error_message = "queue_visibility_timeout_seconds must be an integer between 1 and 43200."
  }
}

# ---- From modules/ingest -----------------------------------------------------

variable "function_name" {
  description = "Ingest function name (modules/ingest output function_name). FunctionName dimension of the Lambda alarms and dashboard widgets."
  type        = string

  validation {
    condition     = length(trimspace(var.function_name)) > 0
    error_message = "function_name must not be empty."
  }
}

variable "function_timeout_seconds" {
  description = "Timeout of the ingest function, in seconds (root local ingest_lambda_timeout_seconds). Drawn as the ceiling line on the Duration widget."
  type        = number

  validation {
    condition     = var.function_timeout_seconds >= 1 && var.function_timeout_seconds <= 900
    error_message = "function_timeout_seconds must be between 1 and 900 (Lambda maximum)."
  }
}

variable "ingest_log_group_name" {
  description = "Log group of the ingest function (modules/ingest output log_group_name). Hosts the TransientFailures metric filter."
  type        = string

  validation {
    condition     = length(trimspace(var.ingest_log_group_name)) > 0
    error_message = "ingest_log_group_name must not be empty."
  }
}

variable "metrics_namespace" {
  description = "Namespace of the ingest EMF metrics (modules/ingest output metrics_namespace). Never re-typed here, so the alarms cannot drift from what the function emits."
  type        = string

  validation {
    condition     = length(trimspace(var.metrics_namespace)) > 0
    error_message = "metrics_namespace must not be empty."
  }
}

# ---- From modules/iot --------------------------------------------------------

variable "topic_rule_name" {
  description = "Telemetry topic rule name (modules/iot output topic_rule_name). RuleName dimension of the silence and rule-failure alarms, and the value matched by the rule-error metric filter."
  type        = string

  # Same character set as IoT rule names; it is also interpolated into a
  # metric filter pattern, where a quote would break the pattern.
  validation {
    condition     = can(regex("^[a-zA-Z0-9_]{1,128}$", var.topic_rule_name))
    error_message = "topic_rule_name must match ^[a-zA-Z0-9_]{1,128}$."
  }
}

variable "rule_error_log_group_name" {
  description = "Log group receiving the topic rule's error documents (modules/iot output rule_error_log_group_name). Hosts the RuleErrorDocuments metric filter."
  type        = string

  validation {
    condition     = length(trimspace(var.rule_error_log_group_name)) > 0
    error_message = "rule_error_log_group_name must not be empty."
  }
}

# ---- From modules/alerting ---------------------------------------------------

variable "fire_alerts_topic_name" {
  description = "Fire-alert topic name (modules/alerting output fire_alerts_topic_name). TopicName dimension of the delivery-failure alarm."
  type        = string

  validation {
    condition     = length(trimspace(var.fire_alerts_topic_name)) > 0
    error_message = "fire_alerts_topic_name must not be empty."
  }
}

variable "ops_topic_arn" {
  description = "Operations topic ARN (modules/alerting output ops_topic_arn). The only alarm and OK action of every alarm in this module."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]{1,256}$", var.ops_topic_arn))
    error_message = "ops_topic_arn must be a standard (non-FIFO) SNS topic ARN."
  }
}

# ---- Policy (ADR-0021 D2) ----------------------------------------------------

variable "telemetry_silence_minutes" {
  description = "Minutes without a single message matched by the telemetry rule before the fleet is declared silent. Operations policy, not mechanism: set by the root as a local, like the detection thresholds (ADR-0020). Must be a multiple of 5 (the alarm uses 5-minute periods) and at most one day (PutMetricAlarm limit for sub-hour periods)."
  type        = number

  validation {
    condition     = var.telemetry_silence_minutes >= 5 && var.telemetry_silence_minutes <= 1440 && var.telemetry_silence_minutes % 5 == 0
    error_message = "telemetry_silence_minutes must be a multiple of 5 between 5 and 1440."
  }
}
