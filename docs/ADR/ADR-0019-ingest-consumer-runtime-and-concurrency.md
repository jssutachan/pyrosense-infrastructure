# ADR-0019: Ingest consumer — runtime, configuration contract, concurrency and IAM scoping

- **Status:** Proposed
- **Date:** 2026-10-06
- **Scope:** `modules/ingest`, `modules/messaging` (two new outputs)
- **Related:** ADR-0002, ADR-0005, ADR-0007, ADR-0008, ADR-0009, ADR-0010, ADR-0011, ADR-0012, ADR-0013, ADR-0015, ADR-0020

## Context

`modules/ingest` deploys the only compute in the pipeline: an SQS-triggered
Lambda whose execution role touches five services (SQS, DynamoDB, S3, SNS,
CloudWatch Logs) and uses the pipeline CMK on four different paths. The
AI-generated draft used the AWS provider `~> 5.0`, X-Ray with a `Resource "*"`
grant, a reserved-concurrency variable, one unscoped KMS statement including
`kms:DescribeKey`, a hard-coded metrics namespace, every design constant as a
module input, and no derivation for `HOT_RETENTION_DAYS`.

With an SQS event source, retries are driven by the queue, not by Lambda: a
failed message reappears after the visibility timeout and moves to the DLQ
after `maxReceiveCount` (ADR-0011). Lambda's asynchronous retry settings do not
apply.

## Decision

**D1 — Runtime and artifact.** `python3.12` on `arm64`, packaged as a zip of
`src/ingest_lambda` (the directory is the zip root, handler
`handler.lambda_handler`), bytecode excluded, file modes pinned to `0644`.
boto3 comes from the managed runtime (ADR-0007).

**D2 — Configuration contract.** Every environment variable `config.py` reads
is injected, including the two with code defaults (`METRICS_NAMESPACE`,
`LOG_LEVEL`). Values identical in demo and prod are module locals (memory,
batch size, concurrency cap, log retention, namespace, log level). Detection
policy (three thresholds and the suppression window) is a required module
input with range validations; its values, and who owns them, are ADR-0020. `HOT_RETENTION_DAYS`
is derived (D6). A plan-time precondition rejects empty values.

**D3 — Concurrency.** No reserved concurrency in either environment. The event
source caps concurrent invocations at 2 (`scaling_config.maximum_concurrency`,
the service minimum).

**D4 — No X-Ray tracing.** `tracing_config` is omitted; Trivy's tracing check
is ignored with the reason inline.

**D5 — KMS grants per service, scoped in a second step.** One statement per
service path, with only the actions that path needs (`kms:Decrypt` for SQS and
DynamoDB, `kms:GenerateDataKey` for S3, `kms:GenerateDataKey*` + `kms:Decrypt`
for SNS). `kms:ViaService` and the DynamoDB and S3 encryption-context
conditions are applied only after the unscoped basic path passes at runtime.

**D6 — Hot-retention floor.** `HOT_RETENTION_DAYS = ceil((DLQ retention +
source retention) / 1 day) + 1` = 19, computed from two new
`modules/messaging` outputs.

## Rationale

- **D1.** 3.12 is what ruff, mypy and pytest prove (`pyproject.toml`); its
  deprecation is scheduled for 2028-10-31. The code has no native extensions,
  so architecture does not matter to it, and arm64 is cheaper per GB-second.
  Excluding `__pycache__` and pinning modes keeps the zip hash stable across
  machines, so the function does not change on a plan with unchanged sources.
- **D2.** If Terraform and the code default could disagree, a dashboard built
  on Terraform's namespace would silently go empty. A threshold hidden as a
  module default would be fire-detection policy inside infrastructure code.
  The validations (smoke > 0; temperature and humidity inside the contract
  ranges, outside which a rule can never fire; suppression 1–1440 minutes
  because the alert slot's TTL is one day) stop Terraform from injecting
  values `config.py` still accepts (debts #15, #23, #24).
- **D3.** Reserved concurrency guarantees capacity against *other* functions
  in the account. There are none, so it buys nothing, and AWS keeps a minimum
  of unreserved concurrency per account: on a new account with a low quota a
  reservation can be refused at apply. If a reservation is ever set, it must
  be ≥ the event source's maximum concurrency, or Lambda throttles the
  mapping's own invocations. The event-source cap is the real brake on cost
  and on downstream load. It is **not** a sufficient brake on email alerts:
  each invocation can publish up to 10 alerts in sequence, so 2 concurrent
  invocations can exceed SNS email's 10 messages/s per subscription during a
  multi-device fire (debt #28 stays open; the fix is aggregation in Python or
  a non-email channel).
- **D4.** Without an X-Ray SDK, the trace records only Lambda's own segments
  (init and invoke); the downstream calls are not instrumented. `Duration`
  already gives that. X-Ray's write actions have no resource-level permissions,
  so tracing would bring the project's only `Resource "*"` identity grant.
- **D5.** The project's lesson from `modules/iot`: one unknown per runtime test.
  An SQS decrypt failure is invisible in function logs (the function is never
  invoked), so the scoping conditions must not be in the first apply that
  proves the basic path. Separate statements also make each grant reviewable
  next to the service that triggers it. `kms:DescribeKey` is dropped: DynamoDB
  uses it when a key is selected for a table, not on item writes.
- **D6.** A duplicate of an already stored message can fail into the DLQ.
  Standard queues keep the original enqueue timestamp in the DLQ, so the copy
  can be up to 14 days old when redriven; redrive restarts the source
  retention (4 days). If the hot item expired first, the conditional write
  accepts the copy as new and the alert fires again. The extra day covers a
  duplicate enqueued after the original was ingested.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| `python3.13` / `3.14` | Newer and supported until 2029, but ruff and mypy target 3.12: moving the runtime alone would deploy code the gate never checked. Move all three together, in a `chore/` branch |
| Bundle boto3 in the zip (AWS's recommendation) | Contradicts ADR-0007 and grows the artifact; the code uses only stable APIs (`put_item`, `put_object`, `publish`). Recorded as a tension, see triggers |
| `reserved_concurrent_executions = maximum_concurrency` | No competing functions; possible quota refusal on a new account |
| X-Ray `Active` (draft) | No instrumentation without an SDK; `Resource "*"` grant |
| One KMS statement with all actions (draft) | Grants S3's and SNS's actions to every path; cannot be scoped per service |
| Scoping conditions in the first apply | A failure could not be attributed to a single cause |
| `HOT_RETENTION_DAYS` as a literal (14) in Python or tfvars | Drifts silently if messaging retention changes; ignores that redrive resets the source clock |
| `filter_criteria` on the mapping | Filtered messages are deleted with no error, metric or DLQ entry |
| AWS managed policies (`AWSLambdaSQSQueueExecutionRole`, `AWSLambdaBasicExecutionRole`) | Grant logs actions on `Resource "*"`, including `CreateLogGroup` |

## Consequences

- `modules/messaging` (verified) gains two outputs; no resource changes, so
  its plan stays `no-op` for existing resources.
- The detection values arrive from root locals governed by ADR-0020; this
  module validates them but does not own them.
- The runtime protocol has two applies (basic, then scoped). In the first
  cycle the scoped policy was applied directly and passed every test, so the
  basic step was not needed; the protocol stays for future policy changes.
- Alert loss on a failed `Publish` remains invisible until the Python change
  for debt #26 lands and observability alarms on it.
- Throughput ceiling at concurrency 2 is unknown until Duration is measured
  (debt #11).

## Runtime verification (2026-10-07, demo)

- D5: every KMS statement and condition matched what the services sent, with
  no failed call in CloudTrail: SQS `Decrypt` (`aws:sqs:arn`), DynamoDB
  `Decrypt` (`aws:dynamodb:tableName`), S3 `GenerateDataKey` only, with the
  bucket ARN as context, and SNS `GenerateDataKey` + `Decrypt`
  (`aws:sns:topicArn`). No `kms:DescribeKey` call.
- Environment variables: each new execution environment calls `kms:Decrypt`
  as the execution role with context `aws:lambda:FunctionArn`, and succeeds
  without any IAM statement allowing it. The Lambda grant on the key is the
  authorization; the grant listing is pending as evidence.
- D1, D2, D3, D6: the function ran on `python3.12`/`arm64` from the zip root,
  received the 11 environment variables, consumed the queue under
  `maximum_concurrency = 2`, and wrote items with a 19-day TTL.

## Revisit triggers

- A second function in the account or Region pool → reserve concurrency ≥ the
  event source's maximum.
- A `load_test` at ~10 msg/s where `ApproximateAgeOfOldestMessage` grows
  without bound, or measured p99 Duration × 10 messages approaches the 30 s
  timeout → raise the cap and/or revisit ADR-0011's timeout.
- Adoption of an X-Ray/ADOT layer → D4.
- A boto3 API change in the managed runtime breaks a test, or the code needs
  an API newer than the runtime ships → bundle the SDK (amends ADR-0007).
- `fix/config-validation` merged → relax the 1440-minute upper bound and
  re-check which validations remain useful.
- Messaging retention changes → nothing to do (derived), but re-read D6 if a
  FIFO queue is ever introduced (FIFO DLQs reset the timestamp).

## References

- Lambda runtimes: https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- Lambda SQS error handling: https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-errorhandling.html
- Lambda SQS configuration: https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html
- Lambda SQS scaling: https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-scaling.html
- Lambda concurrency: https://docs.aws.amazon.com/lambda/latest/dg/lambda-concurrency.html
- Log-level filtering: https://docs.aws.amazon.com/lambda/latest/dg/monitoring-cloudwatchlogs-log-level.html
- Environment variable encryption: https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars-encryption.html
- SQS dead-letter queues: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
- SQS redrive: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-configure-dead-letter-queue-redrive.html
- SQS key management: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-key-management.html
- DynamoDB CMK usage notes: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/encryption.usagenotes.html
- S3 Bucket Keys: https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html
- SNS key management: https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html
- KMS condition keys (`kms:ViaService`): https://docs.aws.amazon.com/kms/latest/developerguide/conditions-kms.html
- X-Ray actions: https://docs.aws.amazon.com/service-authorization/latest/reference/list_awsx-ray.html
- AWSLambdaSQSQueueExecutionRole: https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSLambdaSQSQueueExecutionRole.html
- Trivy AVD-AWS-0066: https://avd.aquasec.com/misconfig/aws/lambda/avd-aws-0066/
- Provider docs (main): `website/docs/r/lambda_function.html.markdown`, `lambda_event_source_mapping.html.markdown`, `cloudwatch_log_group.html.markdown`
