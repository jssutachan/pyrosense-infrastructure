output "table_name" {
  description = "Hot-store table name. Consumer: ingest (TABLE_NAME env var), observability (TableName dimension)."
  value       = aws_dynamodb_table.hot.name
}

output "table_arn" {
  description = "Hot-store table ARN. Consumer: ingest IAM policy (dynamodb:PutItem)."
  value       = aws_dynamodb_table.hot.arn
}

output "bucket_id" {
  description = "Cold-store bucket name. Consumer: ingest (BUCKET_NAME env var), AWS CLI verification."
  value       = aws_s3_bucket.cold.id
}

output "bucket_arn" {
  description = "Cold-store bucket ARN. Consumer: ingest IAM policy (kms:EncryptionContext:aws:s3:arn condition, since bucket keys use the bucket ARN as context)."
  value       = aws_s3_bucket.cold.arn
}

output "telemetry_objects_arn" {
  description = "IAM resource ARN for raw telemetry objects (<bucket_arn>/telemetry/*). Consumer: ingest IAM policy (s3:PutObject), so the key prefix is never re-typed outside this module."
  value       = "${aws_s3_bucket.cold.arn}/${local.telemetry_prefix}*"
}
