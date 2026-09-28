# ==============================================================================
# Root outputs.
#
# Re-exports the modules' outputs so `terraform output` surfaces them after
# apply, without reading the state file. Two audiences:
#   - the operator, verifying a deployment against the AWS CLI;
#   - a reviewer, seeing that the deployment produced what the code claims.
#
# Grouped by module, in the same order as main.tf.
# ==============================================================================

# ------------------------------------------------------------------------------
# module.budgets (ADR-0003)
# ------------------------------------------------------------------------------

output "budget_arn" {
  description = "ARN of the account monthly cost budget."
  value       = module.budgets.budget_arn
}

output "budget_name" {
  description = "Name of the account-wide monthly budget."
  value       = module.budgets.budget_name
}

# ------------------------------------------------------------------------------
# module.security (ADR-0010)
# ------------------------------------------------------------------------------

output "kms_key_arn" {
  description = "ARN of the pipeline encryption key, consumed by every module that stores data at rest."
  value       = module.security.kms_key_arn
}

output "kms_alias_name" {
  description = "Human-readable alias of the pipeline key, for AWS CLI verification."
  value       = module.security.kms_alias_name
}

# ------------------------------------------------------------------------------
# module.messaging (ADR-0008, ADR-0010)
#
# URLs because every SQS CLI call (get-queue-attributes, send-message,
# receive-message) takes --queue-url. ARNs because the redrive contract is
# expressed in ARNs: a reviewer checks that the ingest queue's RedrivePolicy
# names dlq_arn and that the DLQ's RedriveAllowPolicy names ingest_queue_arn.
# Queue names are not re-exported: they are the last path segment of the URL
# and are consumed module-to-module (observability), not by the operator.
# ------------------------------------------------------------------------------

output "ingest_queue_url" {
  description = "URL of the ingest queue, for AWS CLI verification (--queue-url)."
  value       = module.messaging.queue_url
}

output "ingest_queue_arn" {
  description = "ARN of the ingest queue. Must appear in the DLQ's RedriveAllowPolicy sourceQueueArns."
  value       = module.messaging.queue_arn
}

output "ingest_dlq_url" {
  description = "URL of the ingest dead-letter queue, for AWS CLI verification (--queue-url)."
  value       = module.messaging.dlq_url
}

output "ingest_dlq_arn" {
  description = "ARN of the ingest dead-letter queue. Must appear as deadLetterTargetArn in the ingest queue's RedrivePolicy."
  value       = module.messaging.dlq_arn
}


# ------------------------------------------------------------------------------
# module.storage (ADR-0013)
#
# Names because the CLI verification takes them: `aws dynamodb ...
# --table-name` and `aws s3api ... --bucket`. ARNs because the ingest IAM
# policy is scoped to them and a reviewer checks it against these values.
# telemetry_objects_arn is not re-exported: its only consumer (ingest) reads
# it module-to-module, and no CLI command takes an object-ARN pattern.
# ------------------------------------------------------------------------------

output "hot_table_name" {
  description = "Name of the hot-store DynamoDB table, for AWS CLI verification (--table-name)."
  value       = module.storage.table_name
}

output "hot_table_arn" {
  description = "ARN of the hot-store DynamoDB table. The ingest role's dynamodb:PutItem must be scoped to it."
  value       = module.storage.table_arn
}

output "cold_bucket_id" {
  description = "Name of the cold-store S3 bucket, for AWS CLI verification (--bucket)."
  value       = module.storage.bucket_id
}

output "cold_bucket_arn" {
  description = "ARN of the cold-store S3 bucket. With bucket keys enabled it is also the KMS encryption context, so the ingest role's KMS conditions reference it."
  value       = module.storage.bucket_arn
}
