# -----------------------------------------------------------------------------
# modules/observability
#
# Answers, for every boundary of the pipeline, "who finds out if this fails?"
# (ADR-0021). It creates CloudWatch alarms, two log metric filters and one
# dashboard. It creates no data path and holds no data.
#
#   fleet -> IoT Core -> rule -> SQS -> ESM -> Lambda -> S3 / SNS / DynamoDB
#     |        |          |       |             |              |
#   silence  auth      rule     queue age     errors,       fire-alert
#            errors    failure  + DLQ         throttles,    delivery
#                                             transient,
#                                             publish fail
#
# How the signal set was chosen (ADR-0021 D1):
#   - One fault, one page. Each alarm watches the layer where a fault first
#     becomes visible, so downstream symptoms of the same fault are left to
#     the dashboard. Example: a broken payload pages once (DLQ), never also on
#     InvalidPayloads, which counts each of its 5 attempts.
#   - Every alarm notifies the ops topic on ALARM and on OK. Actions fire on
#     state transitions only, so a sustained fault sends one email, not one
#     per period; with 10 alarms the worst burst stays far below the 10 msg/s
#     email ceiling (debt #28). No composite alarm: it would add cost and hide
#     which component failed.
#   - treat_missing_data is chosen per alarm. Failure counters are emitted
#     only when something runs, so missing means healthy (notBreaching). The
#     fleet heartbeat is the opposite: missing means silence (breaching). The
#     DLQ keeps its last state (ignore) because SQS stops emitting metrics for
#     a queue left untouched for six hours, even one that still holds messages.
#
# Not here, on purpose:
#   - No KMS input. Alarms reach the encrypted ops topic as the
#     cloudwatch.amazonaws.com service principal, authorized by the key policy
#     (AllowCloudWatchAlarms in modules/security) and the topic policy
#     (modules/alerting). This module encrypts nothing of its own (debt #22).
#   - No account-level IoT logging (debt #46, ADR-0021 D3).
#   - No automatic replay of IoT rule errors (debt #51, ADR-0021 D4).
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

locals {
  # `region` replaces the `name` attribute, deprecated in AWS provider 6.0.0.
  region = data.aws_region.current.region

  # Metrics derived from logs get their own namespace, one per environment:
  # metric filter metrics cannot carry a constant dimension the log line does
  # not contain, so the environment has to live in the namespace or demo and
  # prod would share one series in a shared account.
  log_metrics_namespace = "PyroSense/LogSignals/${var.environment}"

  # Engineering threshold, derived (review criterion #7). A message that fails
  # transiently reappears every visibility timeout, and SQS drops a message
  # from ApproximateAgeOfOldestMessage after its third receive. So a healthy
  # consumer with transient failures keeps the oldest age below about two
  # visibility timeouts. Above that, the queue is not being drained: the ESM
  # cannot decrypt, is disabled, or the function cannot keep up.
  queue_age_threshold_seconds = 2 * var.queue_visibility_timeout_seconds

  # The silence alarm uses 5-minute periods. The window (policy, ADR-0021 D2)
  # is validated to be a multiple of 5 in variables.tf.
  silence_period_seconds      = 300
  silence_evaluation_periods  = var.telemetry_silence_minutes * 60 / local.silence_period_seconds
  transient_failure_signal    = "TransientFailures"
  rule_error_documents_signal = "RuleErrorDocuments"

  # The keys of local.alarms are part of each alarm's name, so renaming one
  # replaces the alarm.

  alarms = {
    # ---- Edge: is the fleet reporting at all? ----------------------------
    # The only alarm that treats missing data as breaching. TopicMatch counts
    # messages matched by the telemetry rule, so it is the earliest point
    # where "nothing arrives" is measurable: fleet down, certificate revoked,
    # policy denying every topic, rule disabled. Faults after the rule are
    # left to the alarms below (one fault, one page). In demo it fires after
    # every test burst on purpose (ADR-0021 D2); the description stays
    # environment-neutral because it becomes the body of the email.
    telemetry-silence = {
      description         = "No telemetry matched the IoT rule for ${var.telemetry_silence_minutes} minutes. The fleet is silent (sensors down, certificate revoked, publisher stopped or rule disabled)."
      namespace           = "AWS/IoT"
      metric_name         = "TopicMatch"
      dimensions          = { RuleName = var.topic_rule_name }
      statistic           = "Sum"
      period              = local.silence_period_seconds
      evaluation_periods  = local.silence_evaluation_periods
      datapoints_to_alarm = local.silence_evaluation_periods
      threshold           = 1
      comparison_operator = "LessThanThreshold"
      treat_missing_data  = "breaching"
    }

    # A denied publish is telemetry lost at the edge: the IoT policy denies
    # any topic outside .../telemetry/PYRO-T?-???? on purpose, so a
    # misconfigured publisher shows up here instead of vanishing. The metric
    # is account-wide (dimension Protocol only): any MQTT client of the
    # account counts. Connect.AuthError is dashboard-only: a fleet that cannot
    # connect is caught by telemetry-silence.
    iot-publish-auth-errors = {
      description         = "MQTT publishes were denied by IoT Core. Telemetry is being dropped at the edge: a publisher uses a topic or client ID outside the fleet policy, or someone is probing the endpoint. Account-wide metric."
      namespace           = "AWS/IoT"
      metric_name         = "PublishIn.AuthError"
      dimensions          = { Protocol = "MQTT" }
      statistic           = "Sum"
      period              = 300
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 1
      comparison_operator = "GreaterThanOrEqualToThreshold"
      treat_missing_data  = "notBreaching"
    }

    # ---- Rule -> SQS ---------------------------------------------------------
    # Emitted by IoT itself, so it still fires if the error action is broken
    # too (redundancy in the layer that fails, ADR-0015). Every failure is a
    # message that never reached the queue; its payload survives only in the
    # rule error log, with no automatic replay (debt #51).
    iot-rule-sqs-failures = {
      description         = "The IoT rule failed to deliver telemetry to the ingest queue. Each failure is a message outside the pipeline; its payload is only in the rule error log group (base64) and must be replayed by hand (ADR-0021 D4)."
      namespace           = "AWS/IoT"
      metric_name         = "Failure"
      dimensions          = { RuleName = var.topic_rule_name, ActionType = "SQS" }
      statistic           = "Sum"
      period              = 60
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 1
      comparison_operator = "GreaterThanOrEqualToThreshold"
      treat_missing_data  = "notBreaching"
    }

    # ---- Queue -----------------------------------------------------------------
    # The only signal for faults that leave no function log at all: the ESM
    # cannot decrypt the queue, the mapping is disabled, or the function
    # cannot keep up. notBreaching: an empty queue reports no age.
    queue-oldest-message-age = {
      description         = "The oldest message in the ingest queue is older than two visibility timeouts (${local.queue_age_threshold_seconds} s) for 3 minutes. The consumer is not draining the queue: event source mapping disabled or unable to decrypt, or the function is saturated."
      namespace           = "AWS/SQS"
      metric_name         = "ApproximateAgeOfOldestMessage"
      dimensions          = { QueueName = var.queue_name }
      statistic           = "Maximum"
      period              = 60
      evaluation_periods  = 3
      datapoints_to_alarm = 3
      threshold           = local.queue_age_threshold_seconds
      comparison_operator = "GreaterThanThreshold"
      treat_missing_data  = "notBreaching"
    }

    # Any message here exhausted its 5 receives (ADR-0011, ADR-0012). This is
    # the single page for a broken payload; InvalidPayloads (x5 per message)
    # stays on the dashboard (debt #9). ignore, not notBreaching: an untouched
    # queue stops emitting metrics after six hours even while it holds
    # messages, and notBreaching would then clear the alarm with the
    # evidence still sitting in the DLQ.
    dlq-not-empty = {
      description         = "Messages reached the ingest dead-letter queue after 5 failed receives. Either a producer violates contract v1 (InvalidPayloads on the dashboard) or a dependency kept failing (TransientFailures). Never redrive blindly (ADR-0012)."
      namespace           = "AWS/SQS"
      metric_name         = "ApproximateNumberOfMessagesVisible"
      dimensions          = { QueueName = var.dlq_name }
      statistic           = "Maximum"
      period              = 60
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 1
      comparison_operator = "GreaterThanOrEqualToThreshold"
      treat_missing_data  = "ignore"
    }

    # ---- Consumer ----------------------------------------------------------------
    # handler.py catches every per-message exception and reports it in
    # batchItemFailures, so Errors does NOT see a failing S3, KMS or SNS call
    # (verified: 2026-10-07 cycle, failed messages and Errors = 0). It sees
    # what escapes the loop: configuration errors at cold start, timeouts,
    # out-of-memory, a malformed event. Each of those fails the whole batch.
    lambda-errors = {
      description         = "The ingest function itself failed (configuration error at cold start, timeout, out-of-memory or an exception outside the per-message loop). The whole batch returns to the queue. Per-message failures are NOT counted here; see TransientFailures."
      namespace           = "AWS/Lambda"
      metric_name         = "Errors"
      dimensions          = { FunctionName = var.function_name }
      statistic           = "Sum"
      period              = 60
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 1
      comparison_operator = "GreaterThanOrEqualToThreshold"
      treat_missing_data  = "notBreaching"
    }

    # The ESM never runs more than maximum_concurrency = 2 invocations, and
    # the account limit is 10, so a throttle means the account's concurrency
    # pool is exhausted by something else. Whether a throttled SQS invocation
    # consumes a receive (debt #65) is not documented; this alarm makes it
    # visible before it becomes a spurious DLQ entry.
    lambda-throttles = {
      description         = "Invocations of the ingest function were throttled. The event source caps itself at 2 concurrent invocations, so the account concurrency pool is exhausted by other functions. Check for spurious DLQ entries (debt #65)."
      namespace           = "AWS/Lambda"
      metric_name         = "Throttles"
      dimensions          = { FunctionName = var.function_name }
      statistic           = "Sum"
      period              = 60
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 1
      comparison_operator = "GreaterThanOrEqualToThreshold"
      treat_missing_data  = "notBreaching"
    }

    # Per-message dependency failures (S3, DynamoDB, SNS, KMS, IAM), from the
    # metric filter below. Counts attempts, like InvalidPayloads. 3 of 5
    # minutes: a single transient blip retries and heals; a persistent fault
    # under steady traffic fails every minute and pages about 12 minutes
    # before the same messages reach the DLQ.
    transient-failures = {
      description         = "Messages are failing on a dependency (S3, DynamoDB, SNS, KMS or IAM) in at least 3 of the last 5 minutes. They will reach the DLQ after 5 receives (about 15 min). Function logs carry the exception and message_id."
      namespace           = local.log_metrics_namespace
      metric_name         = local.transient_failure_signal
      dimensions          = {}
      statistic           = "Sum"
      period              = 60
      evaluation_periods  = 5
      datapoints_to_alarm = 3
      threshold           = 1
      comparison_operator = "GreaterThanOrEqualToThreshold"
      treat_missing_data  = "notBreaching"
    }

    # The lost-alert alarm required by ADR-0015 decision 2 (debt #26). Every
    # occurrence pages: under claim-before-publish (ADR-0005) the retry finds
    # the window closed and the alert is gone for the suppression window.
    # Requires the AlertPublishFailures EMF counter (P1).
    alert-publish-failures = {
      description         = "A fire alert could not be published to SNS. The suppression slot was already claimed (ADR-0005), so the alert is LOST for the suppression window. Function logs carry a CRITICAL line with device_id and seq: notify responders by hand."
      namespace           = var.metrics_namespace
      metric_name         = "AlertPublishFailures"
      dimensions          = { Environment = var.environment }
      statistic           = "Sum"
      period              = 60
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 1
      comparison_operator = "GreaterThanOrEqualToThreshold"
      treat_missing_data  = "notBreaching"
    }

    # ---- Delivery -------------------------------------------------------------
    # After a successful Publish, SNS may still fail to deliver: for email it
    # counts once, when it stops retrying. This is the only signal that an
    # alert left the pipeline but never reached a responder. The ops topic
    # has no equivalent alarm: it would notify through the channel that failed.
    fire-alert-delivery-failures = {
      description         = "SNS gave up delivering a fire alert to at least one subscriber (bounced or suppressed address, or retries exhausted). The alert was published but a responder did not get it."
      namespace           = "AWS/SNS"
      metric_name         = "NumberOfNotificationsFailed"
      dimensions          = { TopicName = var.fire_alerts_topic_name }
      statistic           = "Sum"
      period              = 300
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 1
      comparison_operator = "GreaterThanOrEqualToThreshold"
      treat_missing_data  = "notBreaching"
    }
  }
}

# -----------------------------------------------------------------------------
# Log-derived signals
#
# Metric filters, not new code: both log lines already exist. The filter
# patterns depend on literal text owned elsewhere (handler.py message,
# IoT error document field); PYTHON-PROPOSALS-observability.md pins the
# handler text with a test.
# -----------------------------------------------------------------------------

# handler.py logs every non-contract exception as JSON on stderr with
# message "Processing failed (message <id>); will retry". Contract
# violations log "Contract violation ...", so they do not match. EMF lines
# (stdout) have no "message" field and do not match either.
# default_value 0: a zero for every non-matching line, so the series is
# continuous while the function runs and absent while it is idle, the same
# shape as the EMF counters. It conflicts with dimensions, which is why the
# environment lives in the namespace.
resource "aws_cloudwatch_log_metric_filter" "transient_failures" {
  name           = "${var.name_prefix}-transient-failures"
  log_group_name = var.ingest_log_group_name
  pattern        = "{ $.message = \"Processing failed*\" }"

  metric_transformation {
    name          = local.transient_failure_signal
    namespace     = local.log_metrics_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# One error document per failed message (ADR-0018). Not an alarm: the same
# event already pages through iot-rule-sqs-failures, which IoT emits even
# when the error action fails. This series is the cross-check on the
# dashboard: Failure minus RuleErrorDocuments = payloads lost without trace.
# Matching the rule name, not "any document", keeps a stray write to the log
# group from being counted.
resource "aws_cloudwatch_log_metric_filter" "rule_error_documents" {
  name           = "${var.name_prefix}-rule-error-documents"
  log_group_name = var.rule_error_log_group_name
  pattern        = "{ $.ruleName = \"${var.topic_rule_name}\" }"

  metric_transformation {
    name          = local.rule_error_documents_signal
    namespace     = local.log_metrics_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# -----------------------------------------------------------------------------
# Alarms
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name        = "${var.name_prefix}-${each.key}"
  alarm_description = each.value.description

  namespace           = each.value.namespace
  metric_name         = each.value.metric_name
  dimensions          = each.value.dimensions
  statistic           = each.value.statistic
  period              = each.value.period
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison_operator
  treat_missing_data  = each.value.treat_missing_data

  # Chosen, not inherited: actions are on in demo too. The demo emails are
  # the evidence that the CloudWatch -> encrypted SNS path works (ADR-0021 D2).
  actions_enabled = true
  alarm_actions   = [var.ops_topic_arn]
  ok_actions      = [var.ops_topic_arn]
  # No insufficient_data_actions: every new alarm starts there, and the
  # alarms whose metrics go quiet are designed not to land there.

  # The metric filters must exist before their alarms evaluate; otherwise a
  # fresh alarm sees an empty namespace and settles on its missing-data state
  # for a reason unrelated to the pipeline.
  depends_on = [
    aws_cloudwatch_log_metric_filter.transient_failures,
    aws_cloudwatch_log_metric_filter.rule_error_documents,
  ]

  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-${each.key}") <= 255
      error_message = "CloudWatch alarm names are limited to 255 characters."
    }

    precondition {
      condition     = length(each.value.description) <= 1024
      error_message = "CloudWatch alarm descriptions are limited to 1024 characters."
    }

    # PutMetricAlarm: with a period under one hour, period x evaluation
    # periods cannot exceed one day.
    precondition {
      condition     = each.value.period * each.value.evaluation_periods <= 86400
      error_message = "Alarm evaluation window (period x evaluation_periods) exceeds 86400 s."
    }
  }
}

# -----------------------------------------------------------------------------
# Dashboard
#
# Laid out as the data flows, so each row compares the two sides of a
# boundary: TopicMatch = Success(SQS) = NumberOfMessagesSent, then
# NumberOfMessagesSent = MessagesStored + DuplicatesSkipped + InvalidPayloads/5
# (when every injected message went through MQTT and every invalid one has
# reached the DLQ).
#
# dashboard_body uses jsonencode by necessity: it is CloudWatch's own widget
# schema, not IAM grammar, so aws_iam_policy_document cannot express it
# (documented exception to convention #10, same reasoning as the SQS redrive
# policy).
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${var.name_prefix}-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "alarm"
        x      = 0
        y      = 0
        width  = 24
        height = 4
        properties = {
          title  = "Alarms"
          alarms = [for a in aws_cloudwatch_metric_alarm.this : a.arn]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 4
        width  = 12
        height = 6
        properties = {
          title  = "1. Edge: IoT Core and the telemetry rule"
          region = local.region
          stat   = "Sum"
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/IoT", "TopicMatch", "RuleName", var.topic_rule_name, { label = "TopicMatch (rule input)" }],
            ["AWS/IoT", "Success", "RuleName", var.topic_rule_name, "ActionType", "SQS", { label = "Success (to SQS)" }],
            ["AWS/IoT", "Failure", "RuleName", var.topic_rule_name, "ActionType", "SQS", { label = "Failure (to SQS)" }],
            [local.log_metrics_namespace, local.rule_error_documents_signal, { label = "Error documents logged" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 4
        width  = 12
        height = 6
        properties = {
          title  = "1b. Edge: MQTT authorization (account-wide)"
          region = local.region
          stat   = "Sum"
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/IoT", "PublishIn.AuthError", "Protocol", "MQTT"],
            ["AWS/IoT", "Connect.AuthError", "Protocol", "MQTT"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 10
        width  = 12
        height = 6
        properties = {
          title  = "2. Buffer: ingest queue and DLQ"
          region = local.region
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", var.queue_name, { stat = "Sum", label = "Sent to queue" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.queue_name, { stat = "Maximum", label = "Queue visible" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.dlq_name, { stat = "Maximum", label = "DLQ visible" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 10
        width  = 12
        height = 6
        properties = {
          title  = "2b. Buffer: oldest message age (s)"
          region = local.region
          stat   = "Maximum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", var.queue_name],
          ]
          annotations = {
            horizontal = [{ label = "Alarm threshold", value = local.queue_age_threshold_seconds }]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 16
        width  = 12
        height = 6
        properties = {
          title  = "3. Consumer: invocations and failures"
          region = local.region
          stat   = "Sum"
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.function_name],
            ["AWS/Lambda", "Errors", "FunctionName", var.function_name],
            ["AWS/Lambda", "Throttles", "FunctionName", var.function_name],
            [local.log_metrics_namespace, local.transient_failure_signal, { label = "Transient failures (attempts)" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 16
        width  = 12
        height = 6
        properties = {
          title  = "3b. Consumer: duration (ms)"
          region = local.region
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", var.function_name, { stat = "Maximum", label = "Maximum" }],
            ["AWS/Lambda", "Duration", "FunctionName", var.function_name, { stat = "p50", label = "p50" }],
          ]
          annotations = {
            horizontal = [{ label = "Timeout", value = var.function_timeout_seconds * 1000 }]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 22
        width  = 12
        height = 6
        properties = {
          title  = "4. Outcomes (EMF): every message ends in exactly one bucket"
          region = local.region
          stat   = "Sum"
          period = 300
          view   = "timeSeries"
          metrics = [
            [var.metrics_namespace, "MessagesStored", "Environment", var.environment],
            [var.metrics_namespace, "DuplicatesSkipped", "Environment", var.environment],
            [var.metrics_namespace, "InvalidPayloads", "Environment", var.environment, { label = "InvalidPayloads (attempts, x5 per message)" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 22
        width  = 12
        height = 6
        properties = {
          title  = "5. Alerts: decided, published, delivered"
          region = local.region
          stat   = "Sum"
          period = 300
          view   = "timeSeries"
          metrics = [
            [var.metrics_namespace, "AlertsPublished", "Environment", var.environment],
            [var.metrics_namespace, "AlertsSuppressed", "Environment", var.environment],
            [var.metrics_namespace, "AlertPublishFailures", "Environment", var.environment],
            ["AWS/SNS", "NumberOfMessagesPublished", "TopicName", var.fire_alerts_topic_name, { label = "SNS published" }],
            ["AWS/SNS", "NumberOfNotificationsDelivered", "TopicName", var.fire_alerts_topic_name, { label = "SNS delivered" }],
            ["AWS/SNS", "NumberOfNotificationsFailed", "TopicName", var.fire_alerts_topic_name, { label = "SNS failed" }],
          ]
        }
      },
    ]
  })
}
