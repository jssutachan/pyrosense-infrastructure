# -----------------------------------------------------------------------------
# modules/ingest
#
# The consumer of the pipeline: an SQS-triggered Lambda that, per message,
# validates contract v1, classifies fire risk, archives the raw body in S3,
# publishes a suppressed alert on CRITICAL risk and commits the hot item with
# a conditional write that doubles as the deduplication guard (ADR-0006,
# ADR-0005, ADR-0008). Order inside the function is load-bearing: the dedup
# commit goes last, so any earlier failure is retried by SQS.
#
# Why it is shaped like this (ADR-0019):
#   - Division of labour, unchanged from modules/messaging (ADR-0011): the
#     handler decides WHICH messages failed and reports them in
#     batchItemFailures; the queue decides WHEN to retry them (visibility
#     timeout) and WHEN to give up (maxReceiveCount -> DLQ). Lambda's
#     asynchronous-invocation retries and function-level DLQ belong to a
#     different invocation model and are not configured.
#   - Partial batch responses (ReportBatchItemFailures), so one bad message
#     never drags the rest of its batch towards the DLQ.
#   - Stdlib-only Python on the managed runtime (ADR-0007): the zip is the
#     source directory, nothing else.
#   - One execution role, one statement per service, every grant bounded by
#     ARN. No managed policies: both Lambda-SQS managed policies grant logs
#     actions on "*" (standard #1).
#   - Unreserved concurrency, capped by the event source (ADR-0019 D3).
#   - No X-Ray: without an SDK the trace shows only Lambda's own segments,
#     and it would bring the project's only Resource "*" IAM grant
#     (ADR-0019 D4).
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

locals {
  # `region` replaces the `name` attribute, deprecated in AWS provider 6.0.0.
  region = data.aws_region.current.region

  function_name = "${var.name_prefix}-ingest"
  role_name     = "${var.name_prefix}-ingest-exec"

  # Design constants: identical in demo and prod (ADR-0002), so neither
  # root variables nor module inputs (review criterion #6).

  # Provisional until debt #11 has real Duration data. Memory also scales
  # CPU, which is what JSON parsing and TLS handshakes to three services use.
  memory_size_mb = 256

  # The code is pure Python with no native wheels, so it is architecture
  # agnostic; arm64 is the cheaper price per GB-second.
  architecture = "arm64"

  # Matches tool.mypy python_version and ruff target-version in pyproject.toml:
  # the runtime the tests prove. Moving it moves those two with it.
  runtime = "python3.12"

  # SQS maximum for a batching window of 0 s; larger batches require a window
  # of at least 1 s (Lambda SQS configuration guide).
  batch_size = 10

  # Event-source cap on concurrent invocations; 2 is the service minimum.
  # Falsifiable: raise it only if a load_test at ~10 msg/s shows the queue's
  # ApproximateAgeOfOldestMessage growing without bound (ADR-0019 D3).
  maximum_concurrency = 2

  # Same retention as the IoT rule error log group: two weeks covers the
  # longest DLQ triage that still needs the matching function logs.
  log_retention_days = 14

  # Single source of the EMF namespace: the function gets it as an env var
  # and observability gets it as an output, so dashboards cannot drift from
  # the code's default.
  metrics_namespace = "PyroSense/Ingest"
  log_level         = "INFO"

  # Hot-retention floor (debt #16). A duplicate of an already stored message
  # can fail into the DLQ, where a standard queue keeps its original enqueue
  # timestamp (oldest at redrive = DLQ retention); redrive then restarts the
  # source retention. If the hot item expires before that redriven copy is
  # processed, the conditional write accepts it as new and the alert fires
  # again (ADR-0008 broken). One extra day covers a duplicate enqueued after
  # the original was ingested. A second blind redrive is out of contract
  # (ADR-0012: never redrive without re-validating).
  hot_retention_days = ceil((var.dlq_message_retention_seconds + var.queue_message_retention_seconds) / 86400) + 1

  # Every key config.py reads, all injected explicitly: METRICS_NAMESPACE and
  # LOG_LEVEL have code defaults, but an explicit value keeps Terraform the
  # single source and makes the plan show the whole contract.
  environment_variables = {
    ENVIRONMENT               = var.environment
    TABLE_NAME                = var.table_name
    BUCKET_NAME               = var.bucket_id
    ALERT_TOPIC_ARN           = var.fire_alerts_topic_arn
    SMOKE_ALERT_PPM           = tostring(var.smoke_alert_ppm)
    TEMP_ALERT_C              = tostring(var.temp_alert_c)
    RH_ALERT_PCT              = tostring(var.rh_alert_pct)
    HOT_RETENTION_DAYS        = tostring(local.hot_retention_days)
    ALERT_SUPPRESSION_MINUTES = tostring(var.alert_suppression_minutes)
    METRICS_NAMESPACE         = local.metrics_namespace
    LOG_LEVEL                 = local.log_level
  }

  # kms:ViaService values; format service.<region>.amazonaws.com.
  via = {
    sqs      = "sqs.${local.region}.amazonaws.com"
    dynamodb = "dynamodb.${local.region}.amazonaws.com"
    s3       = "s3.${local.region}.amazonaws.com"
    sns      = "sns.${local.region}.amazonaws.com"
  }
}

# -----------------------------------------------------------------------------
# Artifact
# -----------------------------------------------------------------------------

# The zip root is the source directory itself: handler.py imports its
# siblings as top-level modules (pyproject: pythonpath = src/ingest_lambda).
# Written under lambda_build/, which .gitignore already covers.
data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/lambda_build/${local.function_name}.zip"

  # Bytecode differs per machine and Python build; leaving it in would change
  # the hash, and therefore the function, on every plan from a new checkout.
  excludes = ["**/__pycache__/**", "**/*.pyc"]

  # Pins file modes so a different umask on another machine (or in CI) does
  # not produce a different zip from identical sources.
  output_file_mode = "0644"
}

# -----------------------------------------------------------------------------
# Logs
# -----------------------------------------------------------------------------

# Declared before the function exists so Lambda never creates it: a
# Lambda-created group has no retention and no CMK (standard #6), and a
# later apply of this resource would fail with ResourceAlreadyExistsException.
# The key policy's AllowCloudWatchLogs statement covers any log group in the
# account, so no change to modules/security is needed.
resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = local.log_retention_days
  kms_key_id        = var.kms_key_arn

  # Explicit rather than inherited: the EMF metrics are extracted from this
  # group, and the cheaper class trades away log features. Not verified for
  # EMF on INFREQUENT_ACCESS; do not change without checking.
  log_group_class = "STANDARD"
}

# -----------------------------------------------------------------------------
# Execution role
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# The workload permissions boundary (ADR-0023) caps this role; the policy
# below remains the exact grant.
resource "aws_iam_role" "ingest" {
  name                 = local.role_name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn

  lifecycle {
    precondition {
      condition     = length(local.role_name) <= 64
      error_message = "IAM role names are limited to 64 characters; shorten name_prefix."
    }
  }
}

# The contract below is the union of the IAM contracts published by
# messaging, storage and alerting, plus logs. Each KMS grant is a separate
# statement so that its scope can be read next to the service that triggers
# it. The `condition` blocks marked STEP 2 are added only after the basic
# path passes at runtime (one unknown per test; ADR-0019 D5).
# Trivy flags the ":*" below as a wildcard. It is the log-stream suffix of
# this function's own log group: stream names are created per execution
# environment, so they cannot be enumerated.
#trivy:ignore:AVD-AWS-0057
data "aws_iam_policy_document" "ingest" {
  # No logs:CreateLogGroup: the group is managed above. The provider exports
  # the group ARN without the trailing ":*", which stream-level actions need.
  statement {
    sid       = "WriteOwnLogStreams"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ingest.arn}:*"]
  }

  # Exactly the three actions of AWS's own SQS-consumer policy, minus its
  # logs actions on "*". The event source polls with this role.
  statement {
    sid       = "ConsumeIngestQueue"
    effect    = "Allow"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [var.queue_arn]
  }

  statement {
    sid       = "DecryptIngestQueue"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    # STEP 2
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.via.sqs]
    }
  }

  # PutItem serves both item families (telemetry and alert slot). The
  # function never reads, updates or deletes.
  statement {
    sid       = "WriteHotStore"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [var.table_arn]
  }

  # No kms:DescribeKey: DynamoDB uses it when a key is selected for a table,
  # not on item writes.
  statement {
    sid       = "DecryptHotStoreTableKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    # STEP 2
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.via.dynamodb]
    }

    # STEP 2
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:dynamodb:tableName"
      values   = [var.table_name]
    }
  }

  statement {
    sid       = "WriteColdStore"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = [var.telemetry_objects_arn]
  }

  # GenerateDataKey only: cold_store.py writes each body with one PutObject;
  # kms:Decrypt is needed for multipart uploads, which the code never does.
  statement {
    sid       = "EncryptColdStoreObjects"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey"]
    resources = [var.kms_key_arn]

    # STEP 2
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.via.s3]
    }

    # STEP 2. With an S3 Bucket Key the context is the bucket ARN, not the
    # object ARN.
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [var.bucket_arn]
    }
  }

  statement {
    sid       = "PublishFireAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.fire_alerts_topic_arn]
  }

  # The pair SNS documents for publishers to an encrypted topic.
  statement {
    sid       = "EncryptFireAlerts"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = [var.kms_key_arn]

    # STEP 2
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.via.sns]
    }
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "ingest-pipeline"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

# -----------------------------------------------------------------------------
# Function
# -----------------------------------------------------------------------------

# Tracing deliberately off (ADR-0019 D4): without an X-Ray SDK the trace
# records only Lambda's own segments, which Duration already covers, and
# enabling it needs a Resource "*" grant.
#trivy:ignore:AVD-AWS-0066
resource "aws_lambda_function" "ingest" {
  function_name = local.function_name
  description   = "PyroSense ingest: validates, classifies, archives, alerts and deduplicates telemetry from SQS"
  role          = aws_iam_role.ingest.arn

  runtime       = local.runtime
  architectures = [local.architecture]
  handler       = "handler.lambda_handler"

  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256

  timeout     = var.timeout_seconds
  memory_size = local.memory_size_mb

  # The environment holds no secrets, but standard #2 applies to everything
  # that supports a CMK. Verified at runtime (2026-10-07): each new execution
  # environment calls kms:Decrypt AS THIS ROLE, with encryption context
  # aws:lambda:FunctionArn, and succeeds although no IAM statement below
  # allows it (every kms:Decrypt here requires an SQS, DynamoDB or SNS
  # ViaService). The authorization is the grant Lambda creates with the
  # deployer's kms:CreateGrant when this key is set, so the role needs no IAM
  # statement for it. Principals that can read the function configuration
  # but lack kms:Decrypt on the key cannot see the values.
  kms_key_arn = var.kms_key_arn

  environment {
    variables = local.environment_variables
  }

  logging_config {
    # Text, explicit: the code writes its own JSON to stderr and EMF to
    # stdout (ADR-0009). The JSON format would wrap each EMF line in a
    # Lambda JSON envelope and metric extraction would stop without error.
    # Level filtering exists only with JSON, so the level is LOG_LEVEL.
    log_format = "Text"

    # The reference also orders the function after its log group.
    log_group = aws_cloudwatch_log_group.ingest.name
  }

  lifecycle {
    precondition {
      condition     = length(local.function_name) <= 64
      error_message = "Lambda function names are limited to 64 characters; shorten name_prefix."
    }

    # config.py reads os.environ.get(name, default): an empty string does not
    # fall back to the default, and require() rejects it only at cold start
    # (debt #25). Fail in plan instead.
    precondition {
      condition     = alltrue([for v in values(local.environment_variables) : trimspace(v) != ""])
      error_message = "Every Lambda environment variable must be non-empty."
    }
  }
}

# -----------------------------------------------------------------------------
# Event source
# -----------------------------------------------------------------------------

resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = var.queue_arn
  function_name    = aws_lambda_function.ingest.arn

  batch_size                         = local.batch_size
  maximum_batching_window_in_seconds = var.batching_window_seconds

  # Without it handler.py's {"batchItemFailures": [...]} is ignored: the whole
  # batch returns on any failure and contract violations drag valid messages
  # to the DLQ.
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = local.maximum_concurrency
  }

  # No filter_criteria on purpose: a filtered-out message is deleted without
  # an error, a metric or a DLQ entry. Invalid messages must reach the
  # function, where they are counted (InvalidPayloads) and kept (DLQ).

  # Lambda checks at creation that the execution role can read the queue.
  # The role ARN alone does not order this after the inline policy.
  depends_on = [aws_iam_role_policy.ingest]

  lifecycle {
    precondition {
      condition     = var.batching_window_seconds >= 1 || local.batch_size <= 10
      error_message = "SQS batch sizes above 10 require a batching window of at least 1 s."
    }
  }
}
