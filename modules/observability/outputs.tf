# What an operator types into the CLI, nothing else. Individual alarm names
# are not exported as a list: the prefix plus the README catalogue is what
# `aws cloudwatch describe-alarms --alarm-name-prefix` needs, and it does not
# change when an alarm is added.

output "alarm_name_prefix" {
  description = "Common prefix of every alarm of this module, for `aws cloudwatch describe-alarms --alarm-name-prefix`. Also how the destroy check proves no alarm is left behind."
  value       = "${var.name_prefix}-"
}

output "alarm_names" {
  description = "Alarm name per signal key (e.g. dlq-not-empty), for `describe-alarm-history --alarm-name` and `set-alarm-state --alarm-name` in the runbook."
  value       = { for k, a in aws_cloudwatch_metric_alarm.this : k => a.alarm_name }
}

output "dashboard_name" {
  description = "Name of the pipeline dashboard (`aws cloudwatch get-dashboard --dashboard-name`)."
  value       = aws_cloudwatch_dashboard.pipeline.dashboard_name
}

output "log_metrics_namespace" {
  description = "Namespace of the metrics derived from logs (TransientFailures, RuleErrorDocuments), for `aws cloudwatch get-metric-statistics --namespace`."
  value       = local.log_metrics_namespace
}
