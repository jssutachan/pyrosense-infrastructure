# Bootstrap stack 1/2: the S3 bucket that stores Terraform state for the
# main configuration.
#
# Chicken-and-egg: the state backend cannot store its own state, so this
# tiny stack intentionally uses LOCAL state. Locking of the main
# configuration uses the native S3 lockfile (Terraform >= 1.11) — no DynamoDB.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "PyroSense"
      Environment = "shared"
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# S3 server access logging is deliberately disabled on the state bucket.
#
# This bucket has exactly one consumer — Terraform, run from the operator's
# workstation — and CloudTrail already records S3 API calls at the account
# level, attributed to the calling identity. Direct anonymous access is
# impossible: full Public Access Block below, plus a bucket policy denying any
# request where aws:SecureTransport is false.
#
# Enabling access logging would require a second bucket, which would itself
# trigger the same rule; the recursion has no terminating case that adds real
# auditing value at this scale.
#
# Confirmed against trivy 0.71.2 on 2026-09-22 (rule AWS-0089, "Bucket has
# logging disabled").
# Revisit if: the state bucket gains consumers beyond Terraform, a CI runner
# assumes a deploy role against it, or an audit requirement mandates
# object-level access records.
#trivy:ignore:AVD-AWS-0089
resource "aws_s3_bucket" "state" {
  bucket = "pyrosense-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3, not a CMK: this stack bootstraps the account before any project
# CMK exists, and state must stay readable even if the pipeline key is
# ever scheduled for deletion (ADR-0001).
#
# Confirmed against trivy 0.71.2 on 2026-09-22: the suppression matches rule
# aws-s3-encryption-customer-key, as reported by the scanner's "Ignore finding"
# output. Revisit in a high-compliance context that requires key-level access
# control and CloudTrail auditing of state bucket encryption.
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter { prefix = "" }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}
