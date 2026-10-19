# Topic ARNs and names only. Subscriptions are not exported: their endpoints
# are email addresses (PII, project standard #11) and nothing downstream
# needs them.

output "fire_alerts_topic_arn" {
  description = "ARN of the fire-risk alert topic. Consumed by ingest: ALERT_TOPIC_ARN env var and the sns:Publish grant of the Lambda role."
  value       = aws_sns_topic.fire_alerts.arn
}

output "fire_alerts_topic_name" {
  description = "Name of the fire-risk alert topic. Consumed by observability as the TopicName dimension of SNS delivery metrics."
  value       = aws_sns_topic.fire_alerts.name
}

output "ops_topic_arn" {
  description = "ARN of the operational alarm topic. Consumed by observability in alarm_actions / ok_actions."
  value       = aws_sns_topic.ops.arn
}

output "ops_topic_name" {
  description = "Name of the operational alarm topic. Consumed by observability as the TopicName dimension of SNS delivery metrics."
  value       = aws_sns_topic.ops.name
}
