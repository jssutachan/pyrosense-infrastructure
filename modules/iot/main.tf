# -----------------------------------------------------------------------------
# modules/iot
#
# The system boundary: who may speak MQTT to AWS IoT Core, and where the
# telemetry goes once it arrives.
#
#   simulator (one mTLS connection, whole fleet)
#       -> IoT Core message broker   [IoT policy: connect + publish only]
#       -> topic rule, SELECT *      [no fields added: closed contract]
#       -> SQS ingest queue          (modules/messaging)
#       -> error action: CloudWatch Logs, own role, own log group
#
# Identity (ADR-0016): the PyroSense-Simulator opens ONE MQTT connection and
# publishes on behalf of every device of every gateway. It is a fleet client,
# not a device and not a gateway, so there is exactly one Thing, one
# certificate and one policy. A per-device policy would deny ~100 % of its
# publishes and protect an identity no sensor in this architecture holds.
#
# Credentials (ADR-0017): the certificate is issued from a CSR. The private
# key is generated on the operator's machine and never reaches Terraform, so
# state holds only public material (CSR + certificate). Everything that is
# not a secret (certificate, Thing, attachments) lives here, which keeps
# zero clickops and lets `terraform destroy` detach and delete in the right
# order.
#
# Topology and error handling (ADR-0018): rule -> SQS -> Lambda, never
# rule -> Lambda (ADR-0011 depends on the queue). No WHERE filter. Action
# failures go to a dedicated log group through a second role, so a broken
# forwarding policy cannot also break the error path (redundancy in the
# layer that fails, ADR-0015).
#
# Account-level IoT logging (aws_iot_logging_options) is deliberately NOT
# here: the provider's delete is a no-op, so a per-cycle destroy would leave
# account logging pointing at a deleted role. It belongs to a persistent
# layer (see README, "Not verified / deferred").
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ATS endpoint: the legacy iot:Data endpoint is signed by Symantec/VeriSign
# CAs that AWS IoT Core no longer supports. The simulator trusts Amazon Root
# CA 1, which matches this endpoint type.
data "aws_iot_endpoint" "data_ats" {
  endpoint_type = "iot:Data-ATS"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # `region` replaces the `name` attribute, deprecated in AWS provider 6.0.0.
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition

  iot_arn_prefix = "arn:${local.partition}:iot:${local.region}:${local.account_id}"

  # One Thing named after the environment; its name IS the MQTT client ID
  # (the policy pins iot:Connect to it).
  fleet_client_name = "${var.name_prefix}-fleet-client"

  # Topic tree shared with the simulator: {base}/{env}/telemetry/{device_id}.
  telemetry_topic_prefix = "${var.topic_base}/${var.environment}/telemetry"
  # MQTT wildcard: exactly one level, as the simulator publishes.
  telemetry_topic_filter = "${local.telemetry_topic_prefix}/+"

  # IoT policy wildcards, not MQTT ones: "?" is exactly one character. The
  # shape mirrors DEVICE_ID_PATTERN = PYRO-T[123]-\d{4} (contract.py, 12
  # characters). Tighter than "*" on purpose: a publish to a deeper or
  # malformed topic would be accepted by "*" but never matched by the rule
  # filter, i.e. a silent loss. With this pattern it is denied and counted
  # in PublishIn.AuthError. Revision trigger: payload contract v2 changing
  # the device_id format.
  device_id_policy_pattern = "PYRO-T?-????"

  # IoT rule names allow only [a-zA-Z0-9_], max 128; name_prefix carries
  # hyphens, so the name is derived here and guarded by a precondition.
  topic_rule_name = replace("${var.name_prefix}_telemetry_to_sqs", "-", "_")

  # Built from the name instead of referencing the rule: the rule needs the
  # role ARNs and the role trust policies need the rule ARN, so a reference
  # would be a dependency cycle.
  topic_rule_arn = "${local.iot_arn_prefix}:rule/${local.topic_rule_name}"

  # Same triage window as the DLQ (14 days, modules/messaging). The error
  # document embeds the original payload (with coordinates), so the log is
  # kept no longer than the queue that holds the same data. Design constant,
  # identical in demo and prod (ADR-0002), hence a local.
  rule_error_retention_days = 14
}

# -----------------------------------------------------------------------------
# Fleet client identity (ADR-0016, ADR-0017)
# -----------------------------------------------------------------------------

resource "aws_iot_thing" "fleet_client" {
  name = local.fleet_client_name
}

# The CSR carries only the public key. With `csr` set, the provider calls
# CreateCertificateFromCsr and never populates private_key or public_key,
# so no key material enters state. certificate_pem is public but the
# provider marks it sensitive; outputs that expose it must be sensitive too.
resource "aws_iot_certificate" "fleet_client" {
  csr    = var.fleet_client_csr_pem
  active = true
}

# EXCLUSIVE_THING: this certificate can be attached to no other Thing, so
# it cannot be reused to impersonate a second client ID.
resource "aws_iot_thing_principal_attachment" "fleet_client" {
  thing                = aws_iot_thing.fleet_client.name
  principal            = aws_iot_certificate.fleet_client.arn
  thing_principal_type = "EXCLUSIVE_THING"
}

# aws_iam_policy_document is valid for IoT policy grammar: same
# Version/Statement/Effect/Action/Resource/Condition shape. IoT policy
# variables use the data source's &{...} escape, which renders as ${...}
# for AWS instead of being interpolated by Terraform. No jsonencode
# exception is needed (convention #10).
data "aws_iam_policy_document" "fleet_client" {
  # Only the client ID equal to the name of a Thing that is registered AND
  # attached to the presented certificate may connect.
  statement {
    sid       = "ConnectAsRegisteredFleetClient"
    effect    = "Allow"
    actions   = ["iot:Connect"]
    resources = ["${local.iot_arn_prefix}:client/&{iot:Connection.Thing.ThingName}"]

    condition {
      test     = "Bool"
      variable = "iot:Connection.Thing.IsAttached"
      values   = ["true"]
    }
  }

  # Publish on behalf of any device of this environment, and nothing else:
  # no other environment, no other topic family, no retained messages
  # (iot:RetainPublish is not granted). iot:Subscribe and iot:Receive are
  # not granted: the simulator never subscribes. The breadth across
  # device_ids is the accepted cost of the fleet-client model (ADR-0016).
  statement {
    sid       = "PublishFleetTelemetry"
    effect    = "Allow"
    actions   = ["iot:Publish"]
    resources = ["${local.iot_arn_prefix}:topic/${local.telemetry_topic_prefix}/${local.device_id_policy_pattern}"]

    # Re-checked on every PUBLISH: detaching the certificate from the Thing
    # stops publishing on the live connection, not only on the next connect.
    condition {
      test     = "Bool"
      variable = "iot:Connection.Thing.IsAttached"
      values   = ["true"]
    }
  }
}

resource "aws_iot_policy" "fleet_client" {
  name   = "${var.name_prefix}-fleet-client"
  policy = data.aws_iam_policy_document.fleet_client.json
}

resource "aws_iot_policy_attachment" "fleet_client" {
  policy = aws_iot_policy.fleet_client.name
  target = aws_iot_certificate.fleet_client.arn
}

# -----------------------------------------------------------------------------
# Topic rule roles (ADR-0018)
# -----------------------------------------------------------------------------

# Confused-deputy protection, per the AWS IoT rule-role example:
# SourceAccount alone would let ANY rule in this account assume the role;
# SourceArn narrows it to this rule. If the ARN were wrong, IoT could not
# assume the role and every action would fail (visible as the Failure
# metric), which is why the runtime DoD checks Success > 0.
data "aws_iam_policy_document" "rule_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["iot.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.topic_rule_arn]
    }
  }
}

# Forwarding role: exactly the producer contract published by
# modules/messaging. KMS permissions sit in this identity policy and reach
# the key through EnableIAMDelegation; no key policy change (debt #12 is
# proven in runtime). kms:ViaService is intentionally not added yet: this
# path has never run, and one unproven condition per runtime test keeps a
# failure attributable.
data "aws_iam_policy_document" "forward" {
  statement {
    sid       = "SendToIngestQueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [var.queue_arn]
  }

  statement {
    sid    = "UsePipelineKeyForQueue"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role" "forward" {
  name               = "${var.name_prefix}-iot-rule-forward"
  assume_role_policy = data.aws_iam_policy_document.rule_trust.json
}

resource "aws_iam_role_policy" "forward" {
  name   = "send-telemetry-to-ingest-queue"
  role   = aws_iam_role.forward.id
  policy = data.aws_iam_policy_document.forward.json
}

# Error role: separate identity so the most plausible regression (an edit
# to the forwarding policy) cannot silence the error path too. No KMS
# permission: CloudWatch Logs encrypts with the CMK as its own service
# principal (AllowCloudWatchLogs in the key policy), not with this role.
data "aws_iam_policy_document" "errors" {
  statement {
    sid    = "WriteRuleErrors"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    # The provider strips the ":*" suffix from the log group ARN; streams
    # live under "<arn>:*".
    resources = [
      aws_cloudwatch_log_group.rule_errors.arn,
      "${aws_cloudwatch_log_group.rule_errors.arn}:*",
    ]
  }
}

resource "aws_iam_role" "errors" {
  name               = "${var.name_prefix}-iot-rule-errors"
  assume_role_policy = data.aws_iam_policy_document.rule_trust.json
}

resource "aws_iam_role_policy" "errors" {
  name   = "write-rule-errors"
  role   = aws_iam_role.errors.id
  policy = data.aws_iam_policy_document.errors.json
}

# -----------------------------------------------------------------------------
# Error destination (ADR-0018)
# -----------------------------------------------------------------------------

# Not the messaging DLQ: that queue holds raw payloads from the consumer's
# redrive, and mixing IoT error documents into it would break "never
# redrive blindly". Encrypted with the pipeline CMK (standard #2): the
# first real use of the AllowCloudWatchLogs key policy statement.
resource "aws_cloudwatch_log_group" "rule_errors" {
  name              = "/aws/iot/${var.name_prefix}/topic-rule-errors"
  retention_in_days = local.rule_error_retention_days
  kms_key_id        = var.kms_key_arn
}

# -----------------------------------------------------------------------------
# Topic rule: MQTT -> SQS
# -----------------------------------------------------------------------------

resource "aws_iot_topic_rule" "telemetry" {
  name        = local.topic_rule_name
  description = "Forwards fleet telemetry unchanged from MQTT into the ingest SQS queue"
  enabled     = true

  # SELECT * with no extra fields: the payload contract is a closed set of
  # keys (contract.py), so a single added field (topic(), timestamp(),
  # clientid()) would turn 100 % of messages into contract violations.
  # No WHERE: under the fleet-client model the publisher controls both the
  # topic and the payload, so a device_id = topic(n) check detects no
  # spoofing, and a message dropped by WHERE is not an action failure, so
  # it would vanish without reaching the error action (ADR-0018).
  sql = "SELECT * FROM '${local.telemetry_topic_filter}'"
  # Chosen, not inherited: 2016-03-23 is the version AWS recommends.
  sql_version = "2016-03-23"

  sqs {
    queue_url = var.queue_url
    role_arn  = aws_iam_role.forward.arn
    # Chosen, not inherited: the consumer parses the body with json.loads
    # and archives it as-is (handler.py, cold_store.py).
    use_base64 = false
  }

  error_action {
    cloudwatch_logs {
      log_group_name = aws_cloudwatch_log_group.rule_errors.name
      role_arn       = aws_iam_role.errors.arn
      # One error document per event; batch mode expects a JSON array of
      # {timestamp, message} records, which an error document is not.
      batch_mode = false
    }
  }

  lifecycle {
    precondition {
      condition     = can(regex("^[a-zA-Z0-9_]{1,128}$", local.topic_rule_name))
      error_message = "Derived topic rule name must match ^[a-zA-Z0-9_]{1,128}$ (AWS IoT CreateTopicRule)."
    }
  }

  # The trust policy only lets THIS rule assume the roles, but IAM is
  # eventually consistent: the roles' permission policies must exist before
  # the rule starts delivering, or the first messages fail into the error
  # path. The implicit dependency only covers the role, not its policy.
  depends_on = [
    aws_iam_role_policy.forward,
    aws_iam_role_policy.errors,
  ]
}
