# Single customer-managed KMS key shared by the whole pipeline (ADR-0010).
# SQS, DynamoDB, S3, SNS and CloudWatch Logs all encrypt at rest with it, so
# key administration, rotation and auditing happen in exactly one place.
#
# Two access paths coexist in the policy below, and the distinction matters:
#   - IAM-delegated: services (SQS, S3, DynamoDB, SNS-on-publish) call KMS
#     using the *caller's* credentials, so the caller's IAM policy decides.
#     One delegation statement covers all of them.
#   - Service principals: CloudWatch Logs, CloudWatch Alarms and SNS-on-
#     delivery call KMS as themselves, with no IAM role to attach a policy to.
#     Each needs its own statement here — this key policy is the only surface
#     where they can be authorized.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # `region` replaces the `name` attribute, deprecated in AWS provider 6.0.0.
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition
}

data "aws_iam_policy_document" "key" {
  # Canonical root statement. Without it the key can become unmanageable (AWS
  # Support is the only recovery path) and IAM policies cannot grant usage at
  # all, because a KMS key denies every principal by default.
  # This is key-policy delegation scoped to this single key, not a wildcard
  # IAM policy. See "Documented exception to project standard #1" in this
  # module's README and in ADR-0010.
  statement {
    sid       = "EnableIAMDelegation"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"] # "*" inside a key policy means "this key".

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # CloudWatch Logs encrypts log groups as its own service principal, which is
  # region-qualified. The encryption context condition is what makes this least
  # privilege: the grant only applies to log groups in this account and region,
  # so a leaked permission cannot be used against anything else.
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }

  # CloudWatch Alarms publish to the KMS-encrypted SNS operations topic. The
  # trailing "*" on GenerateDataKey is load-bearing: AWS has documented alarm
  # failures caused by granting only the exact action name.
  #
  # StringEqualsIfExists, not StringEquals: it is unverified whether CloudWatch
  # populates aws:SourceAccount on its KMS calls. With StringEquals, a missing
  # key silently denies and the alarm never fires. IfExists enforces the value
  # when present and does not block when absent. Tighten to StringEquals only
  # after confirming the key appears in CloudTrail (see ADR-0010).
  statement {
    sid    = "AllowCloudWatchAlarms"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # SNS needs the key when *delivering* to an encrypted SQS queue, including a
  # subscription dead-letter queue. Unconditional, not variable-gated: without
  # a subscription DLQ, SNS discards an alert it cannot deliver, which is the
  # exact failure this platform exists to prevent. Publishing uses the
  # publisher's credentials and is already covered by IAM delegation above.
  statement {
    sid    = "AllowSNSDelivery"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "pipeline" {
  description             = "${var.name_prefix} pipeline encryption at rest (SQS, DynamoDB, S3, SNS, CloudWatch Logs)"
  deletion_window_in_days = var.deletion_window_days
  policy                  = data.aws_iam_policy_document.key.json

  # Annual rotation. rotation_period_in_days is intentionally omitted: the
  # 365-day default is the compliance baseline, and a custom cadence (90-2560)
  # would need its own justification. Note the first two rotations each add a
  # prorated monthly charge.
  enable_key_rotation = true

  # Defaults, stated explicitly so a reviewer sees they were chosen, not
  # inherited: symmetric encrypt/decrypt, single region, active.
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  multi_region             = false
  is_enabled               = true

  # bypass_policy_lockout_safety_check is left at its default (false): the
  # safety check is what prevents shipping a policy that locks us out.
}

resource "aws_kms_alias" "pipeline" {
  name          = "alias/${var.name_prefix}-pipeline"
  target_key_id = aws_kms_key.pipeline.key_id
}
