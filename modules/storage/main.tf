# -----------------------------------------------------------------------------
# modules/storage — hot/cold split of the ingest pipeline (ADR-0013).
#
# Hot:  one DynamoDB table answers "what is happening now". Items expire via
#       TTL; the table is a bounded, derived view, not the system of record.
# Cold: one S3 bucket keeps every raw message byte-for-byte, forever, as the
#       audit trail and analytics source of truth.
#
# Why it is shaped this way:
# - Key schema is dictated by the approved Python, not the other way round:
#   persistence.py writes pk="DEV#<id>"/sk="SEQ#<012d>", alerts.py writes
#   pk="ALERT#<id>"/sk="STATE", both set expires_at (epoch seconds). The
#   conditional put on that key is the at-least-once dedup guard (ADR-0008)
#   and the alert-suppression slot (ADR-0005).
# - The cold bucket does NOT tier to IA/Glacier. cold_store.py writes one
#   small JSON object per message; S3 skips transitions for objects under
#   128 KB by default, and forcing them would cost more than it saves
#   (128 KB minimum billable size in IA, 40 KB per-object overhead in
#   Glacier). Tiering needs compaction first (ADR-0013).
# - One intent, two mechanisms: allow_data_destruction drives both DynamoDB
#   deletion protection and S3 force_destroy, so demo and prod cannot end up
#   half-protected.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  table_name = "${var.name_prefix}-hot"

  # Account id suffix: deterministic, globally unique in practice, nothing
  # hardcoded. See ADR-0013 for the account-regional namespace alternative.
  bucket_name = "${var.name_prefix}-cold-${data.aws_caller_identity.current.account_id}"

  # MUST equal the first path segment of cold_store.KEY_TEMPLATE
  # ("telemetry/dt=.../hour=.../<device>-<seq>.json"). Exported as a
  # ready-to-use IAM resource ARN so ingest never re-types the string.
  # Drift risk between Python and Terraform is tracked as tech debt.
  telemetry_prefix = "telemetry/"

  # AWS default (35), pinned so the recovery window is reviewable in code.
  pitr_recovery_period_days = 35

  # Detection window: how long an overwritten or deleted raw object stays
  # recoverable as a noncurrent version before it is purged.
  noncurrent_version_retention_days = 30

  # The Lambda uses single-part put_object; multipart uploads only come
  # from humans (CLI) and should never linger billing storage.
  abort_incomplete_multipart_days = 7
}

# =============================================================================
# Hot store — DynamoDB
# =============================================================================

resource "aws_dynamodb_table" "hot" {
  name = local.table_name

  # On-demand: ingest traffic is bursty (fire events) and near zero at
  # rest; provisioned capacity would either throttle the burst or pay for
  # idle capacity. Explicit because the provider default is PROVISIONED.
  billing_mode = "PAY_PER_REQUEST"

  # Write-heavy, TTL-bounded table: STANDARD_INFREQUENT_ACCESS trades
  # cheaper storage for pricier requests, the wrong side of this workload.
  table_class = "STANDARD"

  # Generic names because two item families share the table (see header).
  # Only key attributes are declared; declaring non-key attributes causes
  # a perpetual plan diff.
  hash_key  = "pk"
  range_key = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  # Both item families set expires_at as a Number in epoch seconds, the
  # only format TTL honours. Deletion is asynchronous (typically days), so
  # readers must never assume an expired item is gone.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # Always on, not a demo/prod toggle: billed per GB of table size and the
  # table is TTL-bounded, so the demo cost rounds to zero while the prod
  # benefit (restore after a bad deploy) is real.
  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = local.pitr_recovery_period_days
  }

  # CMK instead of the AWS owned key (standard #2). DynamoDB creates grants
  # on this key on behalf of the principal that creates the table; that
  # principal is covered by the key policy's IAM delegation (ADR-0010).
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  deletion_protection_enabled = !var.allow_data_destruction
}

# =============================================================================
# Cold store — S3
# =============================================================================

# Server access logging is off by design, not by omission. AWS requires the
# log destination bucket to use SSE-S3, so enabling it would add a second
# exception to the project's "encrypt with the pipeline CMK" standard (the
# first is the state bucket, ADR-0001). The audit need it covers is narrow
# here: one IAM role writes, and CloudTrail data events can be turned on
# later without touching this bucket.
#trivy:ignore:aws-s3-enable-logging
resource "aws_s3_bucket" "cold" {
  bucket = local.bucket_name

  # Demo: destroy empties the bucket first so the ADR-0002 cycle works
  # (that it also removes noncurrent versions is a runtime check, README). Prod: destroy fails on a non-empty bucket, which
  # is the point. Only effective once applied to state before a destroy.
  force_destroy = var.allow_data_destruction

  lifecycle {
    precondition {
      condition     = length(local.bucket_name) <= 63
      error_message = "Derived bucket name '${local.bucket_name}' exceeds the S3 limit of 63 characters; shorten name_prefix."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cold" {
  bucket = aws_s3_bucket.cold.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Kept although keys are deterministic and retries rewrite identical bytes
# (ADR-0008): determinism protects against *honest* retries, versioning
# protects the audit trail against a buggy or compromised writer that
# overwrites with different bytes. Cost is bounded by the noncurrent
# expiration below.
resource "aws_s3_bucket_versioning" "cold" {
  bucket = aws_s3_bucket.cold.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cold" {
  bucket = aws_s3_bucket.cold.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    # Without a bucket key, every PutObject is one KMS GenerateDataKey call
    # (one per ingested message). With it, S3 reuses a short-lived
    # bucket-level key per requester. Side effect: the KMS encryption
    # context becomes the bucket ARN, not the object ARN; ingest's IAM
    # conditions must use the bucket ARN.
    bucket_key_enabled = true

    # New buckets already block SSE-C by AWS default; stated explicitly so
    # the control is visible in code and drift-detected.
    blocked_encryption_types = ["SSE-C"]
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cold" {
  bucket = aws_s3_bucket.cold.id

  # Noncurrent-version rules on a bucket whose versioning is not yet
  # enabled are meaningless; the provider docs order these explicitly.
  depends_on = [aws_s3_bucket_versioning.cold]

  # No transition and no current-version expiration: raw telemetry is
  # kept in STANDARD indefinitely until compaction exists (ADR-0013).
  # This single rule only bounds the cost of versioning and failed uploads.
  rule {
    id     = "bucket-hygiene"
    status = "Enabled"

    # Explicit empty filter = whole bucket. Rule-level `prefix` is
    # deprecated by S3.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = local.noncurrent_version_retention_days
    }

    # Removes delete markers left with no noncurrent versions behind them.
    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = local.abort_incomplete_multipart_days
    }
  }
}

data "aws_iam_policy_document" "cold_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cold.arn, "${aws_s3_bucket.cold.arn}/*"]

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

# Deny-only: grants nothing. Positive access lives in the ingest IAM role.
resource "aws_s3_bucket_policy" "cold" {
  bucket = aws_s3_bucket.cold.id
  policy = data.aws_iam_policy_document.cold_tls_only.json

  # Serialises two bucket-level PUTs that S3 rejects when concurrent
  # (409 OperationAborted, "conflicting conditional operation"). Without
  # it, a fresh apply fails intermittently depending on scheduling.
  depends_on = [aws_s3_bucket_public_access_block.cold]
}
