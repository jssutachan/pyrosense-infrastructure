# -----------------------------------------------------------------------------
# modules/messaging
#
# Standard SQS queue buffering AWS IoT Core -> ingest Lambda, plus its DLQ.
#   - Absorbs bursts: IoT Core enqueues at sensor publish rate; the Lambda
#     drains at its own concurrency.
#   - Retries transient failures: messages the handler reports as failed
#     (ReportBatchItemFailures) become visible again after the visibility
#     timeout.
#   - Isolates poison messages: after max_receive_count receives, SQS moves the
#     message to the DLQ.
#
# Standard, not FIFO: the IoT Core SQS rule action does not support FIFO
# queues, and ordering is not required because persistence is idempotent
# (ADR-0008: at-least-once delivery + conditional writes).
#
# Retry contract (derived visibility timeout, retention, maxReceiveCount,
# two-sided redrive): ADR-0011.
#
# Encryption: SSE-KMS with the single pipeline CMK (ADR-0010). No new key
# policy statement is needed: the IoT rule role and the Lambda role call KMS
# with their own credentials, covered by EnableIAMDelegation. Those roles'
# IAM policies (owned by modules/iot and modules/ingest, not this module) need:
#   producer (IoT rule role): sqs:SendMessage, kms:GenerateDataKey, kms:Decrypt
#   consumer (Lambda role):   sqs:ReceiveMessage/DeleteMessage/GetQueueAttributes,
#                             kms:Decrypt
# -----------------------------------------------------------------------------

locals {
  # AWS Lambda guidance for SQS event sources: visibility timeout of at least
  # 6x the function timeout, plus the batching window. The extra headroom lets
  # Lambda retry a batch it could not invoke because the function was
  # throttled, without the message reappearing to a second poller while the
  # first batch is still in flight. Derived instead of taken as an input so
  # that no tfvars edit can break the invariant.
  visibility_timeout_seconds = 6 * var.consumer_timeout_seconds + var.consumer_batching_window_seconds

  # Standard queues keep a message's original enqueue timestamp when it moves
  # to the DLQ, so the DLQ retention must be strictly longer than the source
  # retention or a message can expire in the DLQ almost as soon as it lands.
  #   Source: 4 days -> survives a long-weekend consumer outage.
  #   DLQ:   14 days (service maximum) -> at least 10 days of triage window
  #          even for a message that reached the DLQ at the end of its source
  #          retention.
  # These are design constants, not per-environment knobs (ADR-0002: design
  # for production, deploy for demo), hence locals rather than variables.
  message_retention_seconds     = 345600  # 4 days
  dlq_message_retention_seconds = 1209600 # 14 days

  # Receives before a message moves to the DLQ. AWS recommends >= 5 for Lambda
  # consumers so transient failures get several retries. Contract violations
  # also consume all 5 attempts before reaching the DLQ; ADR-0012 accepts that
  # waste. The retry contract itself is ADR-0011.
  max_receive_count = 5

  # How long SQS reuses a KMS data key per principal before calling KMS again.
  # 300 s is the AWS default; kept explicit because it is the knob that trades
  # KMS request volume (cost) against key exposure window. AWS estimate per
  # queue: R = (billing_seconds / reuse_period) * (2 * producers + consumers).
  # With 1 producer and 1 consumer principal over 30 days of continuous
  # traffic: (2592000 / 300) * 3 = 25920 requests/month, the worst case.
  kms_data_key_reuse_period_seconds = 300

  # Both queues get an identical TLS-only policy; for_each keeps each policy
  # scoped to its own queue ARN.
  queues = {
    ingest = aws_sqs_queue.ingest
    dlq    = aws_sqs_queue.dlq
  }
}

resource "aws_sqs_queue" "dlq" {
  name                              = "${var.name_prefix}-ingest-dlq"
  message_retention_seconds         = local.dlq_message_retention_seconds
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = local.kms_data_key_reuse_period_seconds

  lifecycle {
    # Guards the retention invariant against a future edit of the locals.
    precondition {
      condition     = local.dlq_message_retention_seconds > local.message_retention_seconds
      error_message = "DLQ retention must be longer than the ingest queue retention: standard queues keep the original enqueue timestamp when moving a message to the DLQ."
    }
  }
}

resource "aws_sqs_queue" "ingest" {
  name                              = "${var.name_prefix}-ingest"
  visibility_timeout_seconds        = local.visibility_timeout_seconds
  message_retention_seconds         = local.message_retention_seconds
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = local.kms_data_key_reuse_period_seconds

  # redrive_policy is managed by aws_sqs_queue_redrive_policy below, per the
  # provider's recommendation. Do not also set it inline here: two owners of
  # the same attribute produce a perpetual diff.
}

# DLQ side of the redrive contract: only the ingest queue may use this DLQ.
# Without it the default is allowAll, so any queue in the account and Region
# could point its redrive policy here and mix unrelated failures into the
# PyroSense triage queue.
# jsonencode rather than aws_iam_policy_document, by necessity: RedrivePolicy
# and RedriveAllowPolicy are SQS queue attributes with their own JSON schema,
# not IAM policy grammar, so the policy-document data source cannot express
# them. The TLS queue policy below does use aws_iam_policy_document.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.ingest.arn]
  })
}

# Source side of the redrive contract.
resource "aws_sqs_queue_redrive_policy" "ingest" {
  queue_url = aws_sqs_queue.ingest.id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    # Must be a JSON number, not a string; jsonencode of a number guarantees it.
    maxReceiveCount = local.max_receive_count
  })

  # Attach the source only after the DLQ already whitelists it, so there is no
  # window in which the pairing depends on the allowAll default.
  depends_on = [aws_sqs_queue_redrive_allow_policy.dlq]
}

# Resource policy carries only the TLS Deny. Positive access is granted by
# identity policies on the IoT rule role and the Lambda role, so each grant
# lives next to the principal that uses it and can be reviewed in one place;
# the resource policy is a guardrail that no identity policy can override.
data "aws_iam_policy_document" "tls_only" {
  for_each = local.queues

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value.arn]

    # "*" (every principal, including service principals and anonymous
    # callers), which is the intended scope for a transport guardrail.
    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "tls_only" {
  for_each = local.queues

  queue_url = each.value.id
  # aws_iam_policy_document emits Version "2012-10-17" by default; without it
  # the provider warns that create/update can hang until timeout.
  policy = data.aws_iam_policy_document.tls_only[each.key].json
}
