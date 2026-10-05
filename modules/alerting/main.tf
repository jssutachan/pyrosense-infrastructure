# Notification layer of the pipeline: two SNS topics, built for two different
# publishers and two different audiences (ADR-0014).
#
#   fire_alerts - published by the ingest Lambda (alerts.publish_alert) with
#                 its IAM role. Audience: responders. The payload carries
#                 device coordinates, so the topic holds sensitive data.
#   ops         - published by CloudWatch Alarms as a *service principal*,
#                 with no IAM role. Audience: whoever operates the platform.
#
# One module with two explicit topics, not a generic topic module instantiated
# twice: what separates the topics is who publishes and who reads, and that
# difference lives in the policies below as code. A generic module needs a
# flag to express it, and that flag takes a single fixed value per instance
# (ADR-0014).
#
# Delivery is email-only in v1.0 (ADR-0015). Email subscriptions stay pending
# until each recipient confirms; Terraform cannot confirm them, so pending
# subscriptions after apply are expected, not a failed apply.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # Both topics get the same transport guard; keyed by a static name so
  # for_each keys are known at plan time even though the ARNs are not.
  topic_arns = {
    fire_alerts = aws_sns_topic.fire_alerts.arn
    ops         = aws_sns_topic.ops.arn
  }
}

# ------------------------------------------------------------------------------
# Topics
# ------------------------------------------------------------------------------

resource "aws_sns_topic" "fire_alerts" {
  name              = "${var.name_prefix}-fire-alerts"
  kms_master_key_id = var.kms_key_arn

  # Standard, stated explicitly because the Python depends on it:
  # alerts.publish_alert sends no MessageGroupId, which a FIFO topic requires,
  # and FIFO topics cannot deliver to email endpoints at all.
  fifo_topic = false
}

resource "aws_sns_topic" "ops" {
  name              = "${var.name_prefix}-ops-alarms"
  kms_master_key_id = var.kms_key_arn

  # Standard: CloudWatch alarm actions publish without a message group, and
  # the only subscribers are email endpoints.
  fifo_topic = false
}

# ------------------------------------------------------------------------------
# Topic policies
#
# aws_sns_topic_policy replaces the topic's whole Policy attribute, including
# the default statement that let principals of this account act on the topic.
# That is safe for the Lambda (same-account IAM identity policies grant access
# on their own) but NOT for CloudWatch: a service principal has no identity
# policy, so the ops topic needs an explicit Allow or every alarm action fails.
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "tls_only" {
  for_each = local.topic_arns

  # Grants nothing. Positive access comes from IAM (ingest role) or, on the
  # ops topic only, from the CloudWatch statement below.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [each.value]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "ops" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["ops"].json]

  # Confused-deputy guard as AWS documents it for alarm actions: the alarm
  # must live in this account and region. Scoped to alarm:* rather than to
  # the name prefix on purpose: a name-coupled condition would make an alarm
  # named outside the convention fail silently (the failure only shows in
  # the alarm history), and the account is already the trust boundary.
  #
  # StringEquals, not the IfExists variant used in the key policy: here a
  # missing key must deny, otherwise any account's alarms could publish into
  # this topic. The runtime test with set-alarm-state proves CloudWatch
  # populates both keys; if it does not, this statement fails loudly in that
  # test instead of opening the topic.
  statement {
    sid       = "AllowCloudWatchAlarms"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.ops.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:cloudwatch:${local.region}:${local.account_id}:alarm:*"]
    }
  }
}

resource "aws_sns_topic_policy" "fire_alerts" {
  arn    = aws_sns_topic.fire_alerts.arn
  policy = data.aws_iam_policy_document.tls_only["fire_alerts"].json
}

resource "aws_sns_topic_policy" "ops" {
  arn    = aws_sns_topic.ops.arn
  policy = data.aws_iam_policy_document.ops.json
}

# ------------------------------------------------------------------------------
# Email subscriptions
#
# for_each keys are recipient *labels* (e.g. "duty-desk"), never addresses.
# Terraform always discloses for_each keys in resource addresses, so an email
# used as a key would print in every plan, CI log and state address. The
# addresses themselves stay sensitive and render as (sensitive value).
#
# nonsensitive() is safe here because it is applied to keys() only: the labels
# are validated as lowercase role names and contain no address.
# ------------------------------------------------------------------------------

resource "aws_sns_topic_subscription" "fire_alerts" {
  for_each = nonsensitive(toset(keys(var.fire_alert_recipients)))

  topic_arn = aws_sns_topic.fire_alerts.arn
  protocol  = "email"
  endpoint  = var.fire_alert_recipients[each.key]
}

resource "aws_sns_topic_subscription" "ops" {
  for_each = nonsensitive(toset(keys(var.ops_recipients)))

  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = var.ops_recipients[each.key]
}
