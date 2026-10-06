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

# ------------------------------------------------------------------------------
# module.alerting (ADR-0014, ADR-0015)
#
# ARNs only. Every SNS CLI call (get-topic-attributes, publish,
# list-subscriptions-by-topic) takes --topic-arn, and both consumers want the
# ARN too: ingest reads the fire topic ARN as ALERT_TOPIC_ARN, observability
# puts the ops topic ARN in alarm_actions. Topic names are not re-exported:
# they are the last segment of the ARN and their only consumer
# (observability, as the TopicName metric dimension) reads them
# module-to-module. Subscriptions are never exported — their endpoints are
# email addresses (PII, standard #11).
# ------------------------------------------------------------------------------

output "alerts_topic_arn" {
  description = "ARN of the fire-risk alert topic. The ingest Lambda reads it as ALERT_TOPIC_ARN and its role's sns:Publish must be scoped to it."
  value       = module.alerting.fire_alerts_topic_arn
}

output "ops_topic_arn" {
  description = "ARN of the operational alarm topic. Observability references it in alarm_actions / ok_actions; only alarms in this account and region may publish to it."
  value       = module.alerting.ops_topic_arn
}

# ------------------------------------------------------------------------------
# module.iot (ADR-0016, ADR-0017, ADR-0018)
#
# Two audiences again. The operator needs what the simulator needs: the data
# endpoint, the client ID, the issued certificate and the ready-made
# environment block (iot_simulator_env). The CLI verification takes the rest:
# --certificate-id, --target (certificate ARN), --policy-name, --rule-name and
# --log-group-name. Not re-exported: the rule ARN and the topic filter (both
# derivable from the rule name and shown by get-topic-rule), and nothing
# key-related, because no private key ever reaches this configuration.
#
# The certificate PEM is public material, but the provider marks the
# attribute sensitive, so this output must be sensitive too. `terraform
# output -raw` prints it in plain text, which is how the runbook writes it to
# disk.
# ------------------------------------------------------------------------------

output "iot_data_endpoint" {
  description = "AWS IoT Core ATS data endpoint (host name only). Must equal `aws iot describe-endpoint --endpoint-type iot:Data-ATS`."
  value       = module.iot.iot_data_endpoint
}

output "iot_fleet_client_id" {
  description = "MQTT client ID of the fleet client: the Thing name. The IoT policy denies any other client ID."
  value       = module.iot.fleet_client_id
}

output "iot_fleet_client_certificate_id" {
  description = "Fleet client certificate ID, for aws iot describe-certificate --certificate-id."
  value       = module.iot.fleet_client_certificate_id
}

output "iot_fleet_client_certificate_arn" {
  description = "Fleet client certificate ARN, for aws iot list-attached-policies --target."
  value       = module.iot.fleet_client_certificate_arn
}

output "iot_fleet_client_certificate_pem" {
  description = "Public certificate issued from the CSR. Written to the simulator's PYROSENSE_CERT_PATH with terraform output -raw."
  value       = module.iot.fleet_client_certificate_pem
  sensitive   = true
}

output "iot_fleet_client_policy_name" {
  description = "IoT policy attached to the fleet client certificate, for aws iot get-policy --policy-name."
  value       = module.iot.fleet_client_policy_name
}

output "iot_topic_rule_name" {
  description = "Telemetry topic rule, for aws iot get-topic-rule --rule-name and as the RuleName dimension of the AWS/IoT rule metrics."
  value       = module.iot.topic_rule_name
}

output "iot_rule_error_log_group_name" {
  description = "Log group receiving the rule's error documents, for aws logs filter-log-events --log-group-name."
  value       = module.iot.rule_error_log_group_name
}

output "iot_simulator_env" {
  description = "PyroSense-Simulator connection settings (endpoint, topic base, env, client ID), excluding local certificate paths. Render with terraform output -json iot_simulator_env | jq -r 'to_entries[] | \"\\(.key)=\\(.value)\"'."
  value       = module.iot.simulator_env
}
