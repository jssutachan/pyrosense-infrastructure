variable "name_prefix" {
  description = "Queue name prefix assembled by the root module, e.g. \"pyrosense-demo\". Same naming contract as modules/security: lowercase letters, digits and hyphens, at most 64 characters."
  type        = string

  validation {
    # Mirrors the root/security naming contract. 64 + len("-ingest-dlq") = 75,
    # within the 80-character SQS queue name limit.
    condition     = can(regex("^[a-z0-9-]{1,64}$", var.name_prefix))
    error_message = "name_prefix must be 1-64 characters of lowercase letters, digits and hyphens."
  }
}

variable "kms_key_arn" {
  description = "ARN of the pipeline CMK (module.security.kms_key_arn, ADR-0010) used for SSE-KMS on both queues."
  type        = string

  validation {
    # A key ARN, not an alias or bare key id: SQS would accept either, but the
    # producer/consumer IAM policies in modules/iot and modules/ingest must name
    # the full key ARN in Resource, so the whole pipeline wires the same value.
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>), not an alias or a bare key id."
  }
}

variable "consumer_timeout_seconds" {
  description = "Timeout of the ingest Lambda (the queue's consumer). Pass the same root-level value that modules/ingest uses; the queue visibility timeout is derived from it."
  type        = number

  validation {
    # Lambda timeout range: 1-900 s. This also bounds the derived visibility
    # timeout at 6 * 900 + 300 = 5700 s, well under the SQS max of 43200 s.
    condition     = var.consumer_timeout_seconds >= 1 && var.consumer_timeout_seconds <= 900 && floor(var.consumer_timeout_seconds) == var.consumer_timeout_seconds
    error_message = "consumer_timeout_seconds must be an integer between 1 and 900 (Lambda timeout range)."
  }
}

variable "consumer_batching_window_seconds" {
  description = "MaximumBatchingWindowInSeconds of the ingest Lambda event source mapping. Pass the same root-level value that modules/ingest uses."
  type        = number

  validation {
    condition     = var.consumer_batching_window_seconds >= 0 && var.consumer_batching_window_seconds <= 300 && floor(var.consumer_batching_window_seconds) == var.consumer_batching_window_seconds
    error_message = "consumer_batching_window_seconds must be an integer between 0 and 300."
  }
}
