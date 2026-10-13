# Consumers: the root (re-exports what an operator types into the AWS CLI)
# and modules/observability (alarm dimensions, log metric filters, the EMF
# namespace). Nothing here is sensitive: names, ARNs and an ESM UUID.

output "function_name" {
  description = "Ingest function name. CloudWatch dimension FunctionName (observability) and --function-name in the AWS CLI."
  value       = aws_lambda_function.ingest.function_name
}

output "function_arn" {
  description = "Ingest function ARN, for reviewers comparing it against the event source mapping and CloudTrail records."
  value       = aws_lambda_function.ingest.arn
}

output "role_arn" {
  description = "Execution role ARN. The identity to look for in CloudTrail when proving that the role, not an admin, made the KMS, DynamoDB, S3 and SNS calls."
  value       = aws_iam_role.ingest.arn
}

output "log_group_name" {
  description = "Function log group. Consumed by observability (metric filters, Logs Insights) and by `aws logs filter-log-events --log-group-name`."
  value       = aws_cloudwatch_log_group.ingest.name
}

output "event_source_mapping_uuid" {
  description = "UUID of the SQS event source mapping. `aws lambda get-event-source-mapping --uuid` takes this, not a name or an ARN."
  value       = aws_lambda_event_source_mapping.sqs.uuid
}

output "metrics_namespace" {
  description = "CloudWatch namespace of the function's EMF metrics (MessagesStored, DuplicatesSkipped, InvalidPayloads, AlertsPublished, AlertsSuppressed; dimension Environment). Consumed by observability."
  value       = local.metrics_namespace
}

output "hot_retention_days" {
  description = "Derived TTL horizon injected as HOT_RETENTION_DAYS. Exported so the plan and the README show the value the dedup guarantee rests on."
  value       = local.hot_retention_days
}
