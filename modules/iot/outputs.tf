# Consumers:
#   root outputs  -> operator runbook (simulator .env, certificate file).
#   modules/observability -> topic_rule_name (RuleName dimension of the
#     AWS/IoT rule and rule-action metrics), rule_error_log_group_name.

output "iot_data_endpoint" {
  description = "AWS IoT Core ATS data endpoint (host name only, no scheme, no port), as the simulator's PYROSENSE_IOT_ENDPOINT expects. The SDK picks port 443 (ALPN) or 8883."
  value       = data.aws_iot_endpoint.data_ats.endpoint_address
}

output "fleet_client_id" {
  description = "MQTT client ID the simulator must use (PYROSENSE_CLIENT_ID). Equals the Thing name; the IoT policy denies any other client ID."
  value       = aws_iot_thing.fleet_client.name
}

output "fleet_client_certificate_id" {
  description = "ID of the fleet client certificate, for aws iot describe-certificate --certificate-id."
  value       = aws_iot_certificate.fleet_client.id
}

output "fleet_client_certificate_arn" {
  description = "ARN of the fleet client certificate, for aws iot list-attached-policies --target."
  value       = aws_iot_certificate.fleet_client.arn
}

output "fleet_client_certificate_pem" {
  description = "Public X.509 certificate issued from the CSR, written by the operator to the simulator's PYROSENSE_CERT_PATH. Not a secret, but the provider marks the attribute sensitive, so this output must be too."
  value       = aws_iot_certificate.fleet_client.certificate_pem
  sensitive   = true
}

output "fleet_client_policy_name" {
  description = "Name of the IoT policy attached to the fleet client certificate (aws iot get-policy --policy-name)."
  value       = aws_iot_policy.fleet_client.name
}

output "telemetry_topic_filter" {
  description = "MQTT topic filter of the topic rule: {base}/{env}/telemetry/+."
  value       = local.telemetry_topic_filter
}

output "topic_rule_name" {
  description = "Topic rule name: RuleName dimension of the AWS/IoT TopicMatch, Success, Failure, ErrorActionSuccess and ErrorActionFailure metrics."
  value       = aws_iot_topic_rule.telemetry.name
}

output "topic_rule_arn" {
  description = "ARN of the telemetry topic rule (the aws:SourceArn the rule roles trust)."
  value       = aws_iot_topic_rule.telemetry.arn
}

output "rule_error_log_group_name" {
  description = "Log group receiving the rule's error documents (failed SQS deliveries, base64 original payload included)."
  value       = aws_cloudwatch_log_group.rule_errors.name
}

# Single source of truth for the simulator's connection settings: the topic
# tree and client ID are owned here, so the simulator reads them instead of
# relying on its own defaults (its env default "dev" never matches an
# environment of this project). Certificate paths are local to the operator
# and deliberately absent.
output "simulator_env" {
  description = "Environment variables for PyroSense-Simulator's MqttSettings, excluding local certificate paths. Render with: terraform output -json simulator_env | jq -r 'to_entries[] | \"\\(.key)=\\(.value)\"'."
  value = {
    PYROSENSE_IOT_ENDPOINT = data.aws_iot_endpoint.data_ats.endpoint_address
    PYROSENSE_TOPIC_BASE   = var.topic_base
    PYROSENSE_ENV          = var.environment
    PYROSENSE_CLIENT_ID    = aws_iot_thing.fleet_client.name
  }
}
