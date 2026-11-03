#!/usr/bin/env bash
# Post-apply smoke test of demo (ADR-0025): is every part deployed, enabled
# and wired to the next one?
#
# Control plane only. It uses the configuration reads both pipeline roles
# already have and never touches data: sending telemetry needs the fleet
# client's private key, which never leaves the operator's machine (ADR-0017),
# so the end-to-end data test stays with the operator.
#
# Prints check names and PASS/FAIL only. Terraform outputs carry ARNs (the
# account id) and subscriptions carry email addresses, and the workflow log
# is public, so no AWS CLI output and no error text reaches stdout.
#
# Run from the repository root, after `terraform apply`, with AWS credentials.
set -euo pipefail

out() { terraform output -raw "$1"; }

failures=0
check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    failures=$((failures + 1))
  fi
}

# equals <expected> <command...>: the command's text output must equal expected.
equals() {
  local expected=$1
  shift
  local actual
  actual="$("$@")" || return 1
  [[ "$actual" == "$expected" ]]
}

lambda_ready() {
  equals $'Active\tSuccessful' aws lambda get-function \
    --function-name "$(out ingest_function_name)" \
    --query 'Configuration.[State,LastUpdateStatus]' --output text
}

mapping_enabled() {
  equals Enabled aws lambda get-event-source-mapping \
    --uuid "$(out ingest_event_source_mapping_uuid)" --query State --output text
}

certificate_active() {
  equals ACTIVE aws iot describe-certificate \
    --certificate-id "$(out iot_fleet_client_certificate_id)" \
    --query certificateDescription.status --output text
}

certificate_has_policy() {
  equals 1 aws iot list-attached-policies \
    --target "$(out iot_fleet_client_certificate_arn)" \
    --query "length(policies[?policyName=='$(out iot_fleet_client_policy_name)'])" --output text
}

rule_enabled() {
  equals False aws iot get-topic-rule --rule-name "$(out iot_topic_rule_name)" \
    --query rule.ruleDisabled --output text
}

queue_redrives_to_dlq() {
  local policy
  policy="$(aws sqs get-queue-attributes --queue-url "$(out ingest_queue_url)" \
    --attribute-names RedrivePolicy --query Attributes.RedrivePolicy --output text)"
  [[ "$(jq -r .deadLetterTargetArn <<<"$policy")" == "$(out ingest_dlq_arn)" ]]
}

dlq_empty() {
  equals 0 aws sqs get-queue-attributes --queue-url "$(out ingest_dlq_url)" \
    --attribute-names ApproximateNumberOfMessages \
    --query Attributes.ApproximateNumberOfMessages --output text
}

key_enabled_and_rotating() {
  equals Enabled aws kms describe-key --key-id "$(out kms_key_arn)" \
    --query KeyMetadata.KeyState --output text &&
    equals True aws kms get-key-rotation-status --key-id "$(out kms_key_arn)" \
      --query KeyRotationEnabled --output text
}

table_active_and_encrypted() {
  equals $'ACTIVE\tENABLED' aws dynamodb describe-table --table-name "$(out hot_table_name)" \
    --query 'Table.[TableStatus,SSEDescription.Status]' --output text
}

bucket_uses_kms() {
  equals aws:kms aws s3api get-bucket-encryption --bucket "$(out cold_bucket_id)" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
    --output text
}

all_alarms_exist() {
  local expected
  expected="$(terraform output -json observability_alarm_names | jq length)"
  equals "$expected" aws cloudwatch describe-alarms \
    --alarm-name-prefix "$(out observability_alarm_name_prefix)" \
    --query 'length(MetricAlarms)' --output text
}

topic_has_subscriptions() {
  local count
  count="$(aws sns list-subscriptions-by-topic --topic-arn "$(out "$1")" \
    --query 'length(Subscriptions)' --output text)"
  [[ "$count" -ge 1 ]]
}

check "ingest function active and updated" lambda_ready
check "queue -> function mapping enabled" mapping_enabled
check "fleet client certificate active" certificate_active
check "fleet client policy attached to the certificate" certificate_has_policy
check "telemetry topic rule enabled" rule_enabled
check "ingest queue redrives to the DLQ" queue_redrives_to_dlq
check "DLQ empty" dlq_empty
check "pipeline key enabled, rotation on" key_enabled_and_rotating
check "hot table active, encrypted" table_active_and_encrypted
check "cold bucket encrypted with KMS" bucket_uses_kms
check "every observability alarm exists" all_alarms_exist
check "fire-alert topic has subscriptions" topic_has_subscriptions alerts_topic_arn
check "ops topic has subscriptions" topic_has_subscriptions ops_topic_arn

# Email subscriptions stay pending until a person confirms them (ADR-0015).
# Expected right after an apply; reported, not failed.
pending=0
for topic in alerts_topic_arn ops_topic_arn; do
  n="$(aws sns list-subscriptions-by-topic --topic-arn "$(out "$topic")" \
    --query "length(Subscriptions[?SubscriptionArn=='PendingConfirmation'])" \
    --output text 2>/dev/null || echo 0)"
  pending=$((pending + n))
done
printf 'INFO  %s email subscription(s) pending confirmation (scripts/alerting/sns-confirm.sh)\n' "$pending"

if ((failures > 0)); then
  printf '%s smoke check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all smoke checks passed\n'
