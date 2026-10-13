# Consumers: modules/iot (queue ARN for the rule action and its role policy),
# modules/ingest (queue ARN for the event source mapping and the Lambda role),
# modules/observability (queue and DLQ names for CloudWatch alarm dimensions).

output "queue_arn" {
  description = "ARN of the ingest queue. Used in the IoT rule role policy (sqs:SendMessage) and the Lambda event source mapping."
  value       = aws_sqs_queue.ingest.arn
}

output "queue_url" {
  description = "URL of the ingest queue. Required by the IoT Core SQS rule action and by SQS API/CLI calls."
  value       = aws_sqs_queue.ingest.url
}

output "queue_name" {
  description = "Name of the ingest queue. CloudWatch metric dimension QueueName."
  value       = aws_sqs_queue.ingest.name
}

output "dlq_arn" {
  description = "ARN of the dead-letter queue. Used for redrive (StartMessageMoveTask) permissions and triage tooling."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  description = "URL of the dead-letter queue."
  value       = aws_sqs_queue.dlq.url
}

output "dlq_name" {
  description = "Name of the dead-letter queue. CloudWatch metric dimension QueueName for the DLQ depth alarm."
  value       = aws_sqs_queue.dlq.name
}

# Retention values are exported for modules/ingest, which derives the hot
# store's TTL floor from them (debt #16): a message redriven from the DLQ can
# be as old as the DLQ retention (standard queues keep the original enqueue
# timestamp) and then waits up to the source retention again (redrive resets
# it). Exporting the locals keeps that derivation correct if either changes.

output "message_retention_seconds" {
  description = "Retention of the ingest queue, in seconds. Consumed by modules/ingest to derive HOT_RETENTION_DAYS."
  value       = aws_sqs_queue.ingest.message_retention_seconds
}

output "dlq_message_retention_seconds" {
  description = "Retention of the DLQ, in seconds. Consumed by modules/ingest to derive HOT_RETENTION_DAYS."
  value       = aws_sqs_queue.dlq.message_retention_seconds
}
