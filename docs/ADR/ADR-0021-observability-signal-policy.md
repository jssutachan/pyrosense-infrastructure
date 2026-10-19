# ADR-0021: Observability — one fault, one page; fleet silence as a breaching heartbeat; no account-level IoT logging and manual replay in v1.0

- **Status:** Proposed
- **Date:** 2026-10-08
- **Scope:** `modules/observability`; operational contract of every module
- **Related:** ADR-0002 (design for prod, deploy for demo), ADR-0005 (claim-before-publish), ADR-0009 (logs and EMF), ADR-0011 (retry contract), ADR-0012 (permanent failures stay on the retry path), ADR-0015 (email-only alerts; publish failure must be observable), ADR-0018 (IoT rule error action), ADR-0019 (ingest consumer), ADR-0020 (policy vs mechanism)

## Context

v1.0 had every data path built and verified, and no component that answered
"who finds out if this fails?". Several failure modes left no trace at all:

- A per-message dependency failure (S3, DynamoDB, SNS, KMS) is caught by
  `handler.py` and reported in `batchItemFailures`. The invocation succeeds, so
  Lambda `Errors` stays at 0. Verified on 2026-10-07: messages failed (T4, T5)
  and `Errors` summed 0 over 21 invocations.
- A failed alert publish is recorded as `AlertsSuppressed` on the retry
  (ADR-0005, debt #26). ADR-0015 decision 2 makes it a v1.0 blocker.
- An IoT rule action failure leaves the payload only in a log group, with no
  retry (ADR-0018, debt #51).
- When the ESM cannot decrypt the queue, the function is never invoked and
  writes no log.
- When nothing publishes, every error counter stays silent, because there is
  nothing to count.

Two constraints shape the design:

1. **Delivery.** The only operator channel is the KMS-encrypted ops topic with
   email subscriptions (ADR-0015). Email is capped at 10 messages/s per
   subscription; exceeding it suspends the subscription for 30 days.
2. **Metric absence.** Absence of data means different things per metric.
   Lambda and IoT counters emit nothing while idle, while the EMF counters emit
   zeros on every invocation. SQS stops emitting for a queue untouched for six
   hours, even one that still holds messages. The default `missing` treatment
   would leave most alarms in `INSUFFICIENT_DATA` or clear them at the wrong
   moment.

## Decision

### D1 — Signal set: each fault pages once, at the layer where it first becomes visible

| Signal (alarm key) | Metric | Fault it owns |
|---|---|---|
| `telemetry-silence` | `AWS/IoT TopicMatch` | Nothing reaches the rule (see D2) |
| `iot-publish-auth-errors` | `AWS/IoT PublishIn.AuthError` | Publishes denied at the edge (lost telemetry) |
| `iot-rule-sqs-failures` | `AWS/IoT Failure` (`ActionType=SQS`) | Rule → queue delivery failed (payload only in the error log) |
| `queue-oldest-message-age` | `AWS/SQS ApproximateAgeOfOldestMessage` > 2 × VT | Queue not drained (ESM disabled or unable to decrypt, saturation) |
| `dlq-not-empty` | `AWS/SQS ApproximateNumberOfMessagesVisible` (DLQ) | A message exhausted its receives |
| `lambda-errors` | `AWS/Lambda Errors` | The invocation itself failed (config, timeout, OOM) |
| `lambda-throttles` | `AWS/Lambda Throttles` | Account concurrency exhausted (debt #65) |
| `transient-failures` | Metric filter on `"Processing failed*"` | Per-message dependency failures, 3 of 5 minutes |
| `alert-publish-failures` | EMF `AlertPublishFailures` (P1) | A fire alert was lost (ADR-0015 D2) |
| `fire-alert-delivery-failures` | `AWS/SNS NumberOfNotificationsFailed` (fire topic) | Alert published but not delivered |

The following are on the dashboard only. Each is either a downstream symptom of
a fault that already pages, or a value without an action:

- `InvalidPayloads`: ×5 per message; the DLQ pages once.
- `Connect.AuthError`: a silent fleet pages through `telemetry-silence`.
- `ErrorActionFailure` / `RuleErrorDocuments`: the cross-check for rule failures.
- Lambda `Duration`: see D5.
- DynamoDB throttling and system errors: they surface as `transient-failures`.
- `MessagesStored`, `DuplicatesSkipped`, `AlertsPublished` and `AlertsSuppressed`.

Every alarm sends to the ops topic on `ALARM` and on `OK`. Actions fire on
state transitions, not on every period, so a sustained fault produces one
email. With 10 alarms, the worst simultaneous burst is 10 emails, an order of
magnitude below the per-second ceiling. No composite alarm.

`treat_missing_data` is set per alarm:

- `notBreaching` for failure counters.
- `breaching` for the heartbeat (D2).
- `ignore` for the DLQ, so a dormant queue that still holds messages does not
  silently return to `OK`.

### D2 — Fleet silence is an alarm, and it stays armed in demo

- **Metric.** `TopicMatch` on the telemetry rule, `Sum < 1` for
  `telemetry_silence_minutes` (5-minute periods), with `treat_missing_data =
  breaching`. `TopicMatch` is the earliest boundary where "nothing arrives" can
  be measured. Faults after it already have their own alarm: rule failure,
  queue age, consumer.
- **Window.** `telemetry_silence_minutes` is operations policy (like ADR-0020),
  set as a root `local`. Provisional value: 10 minutes. Owner: whoever owns the
  sensor reporting cadence, today unassigned.
- **Not a demo/prod delta.** In demo the alarm fires roughly 10 minutes after
  every test burst and clears at the next one. That is a handful of emails per
  cycle, and they are the evidence that the CloudWatch → encrypted SNS path
  works. No `actions_enabled` variable.

### D3 — No account-level IoT logging in v1.0 (debt #46)

`aws_iot_logging_options` is account-wide configuration, and its delete is a
no-op in the provider. In a project that destroys every module each cycle, it
would outlive the role it points to and keep ingesting logs.

The diagnostics it would add are per-connection and per-publish traces. They
matter when the rule metrics are not enough to explain an `AuthError` or a
`Failure`. They can be switched on temporarily, by an operator, during an
investigation.

### D4 — IoT rule errors: page on the metric, replay by hand (debt #51)

- The page comes from `AWS/IoT Failure`, which IoT emits even if the error
  action is broken too.
- A metric filter on the error log group counts error documents for the
  dashboard. `Failure − RuleErrorDocuments` is the number of payloads lost
  without trace.
- Replay is manual. Decode `base64OriginalPayload` from the log, then send the
  decoded body to the ingest queue with `aws sqs send-message`. The rule adds
  nothing to the body, so a direct send is byte-identical to the original path.
- Automating it, by a script or an error action into a second queue, is
  deferred to post-v1.0.

### D5 — Duration: no alarm; the 30 s timeout stands (debt #11)

Data from the 2026-10-07 cycle: 21 invocations, p50 52 ms, p90 1606 ms,
p99 1711 ms, max 1715 ms.

- `Duration` excludes init time. The ~1.6 s tail is therefore inside the
  handler: first-call client creation and TLS, because `get_s3()`/`get_sns()`
  are lazy.
- The worst invocation used 5.7 % of the timeout.
- A timeout already pages through `lambda-errors`. A `Duration` alarm would be
  a second page for the same fault, so `Duration` stays on the dashboard (max
  and p50, with the timeout drawn as a line).
- The timeout is not lowered. The visibility timeout and the time to DLQ derive
  from it (ADR-0011), and 21 demo samples do not justify retuning the retry
  contract.

## Rationale

- **Page where the fault starts.** An operator needs the first signal and its
  cause, not every echo. Choosing the layer instead of piling up thresholds
  keeps the page count bounded by the number of independent faults.
- **Missing data is a design input.** Each metric's emission rules (verified,
  see References) decide its treatment. A uniform `notBreaching`, as in the
  first draft, would make the silence alarm impossible and would let the DLQ
  alarm clear while messages remain.
- **Redundancy in the layer that fails** (ADR-0015). The rule alarm uses the
  metric IoT emits itself, not the log written by the error action that might
  be the thing failing.

## Alternatives considered

| Alternative | Why not |
|---|---|
| `notBreaching` on every alarm (first draft) | No silence detection; the DLQ alarm clears after six dormant hours with messages still inside. |
| Alarm on `InvalidPayloads` as well as the DLQ | Five pages per broken message, and the DLQ already pages once. |
| Composite alarm for storm control | +$0.50/month and one opaque email; the signal set is already non-overlapping and transitions are rate-bounded. |
| No `ok_actions` | Halves the emails, but the operator never learns a fault cleared. |
| Silence on `MessagesStored` (EMF) | It also fires on consumer and rule faults that already page: two pages for one fault. |
| Silence on SQS `NumberOfMessagesSent` | It misses a rule that matches but fails (already paged), and SQS stops emitting for dormant queues. |
| `actions_enabled = false` for silence in demo (root variable) | It hides the only end-to-end proof of the path in the environment that is actually deployed. Fatigue is not a concern for a single operator in a cycle of a few hours. |
| Alarm on log-derived `RuleErrorDocuments` | It depends on the error action working, which is the layer that may have failed. |
| `Duration` p99 alarm | Percentiles of a few samples are the maximum, and a timeout already pages via `Errors`. |
| Enable ESM `metrics_config` (`EventCount`) | It modifies a verified module for counts that `NumberOfMessagesSent`, `Invocations` and the EMF already give. Queue age covers the "ESM not consuming" case. |
| Account-level IoT logging at `ERROR` | Orphaned on destroy (no-op delete), account-wide, and not needed while rule metrics explain failures. |

## Consequences

- **Cost.** 10 standard alarms ($0.10 each per month) and 2 new custom metrics
  from metric filters ($0.30 each per month), plus `AlertPublishFailures` from
  P1. One dashboard, within the 3-dashboard free tier.
- **Two contracts outside Terraform** that the alarms now depend on:
  - The literal log message prefix `"Processing failed"` in `handler.py`.
  - The EMF counter `AlertPublishFailures` (P1).

  Both are pinned by tests (`PYTHON-PROPOSALS-observability.md`).
- **Two changes to verified modules.**
  - `modules/messaging` gains output `visibility_timeout_seconds`.
  - `modules/security` hardens `AllowCloudWatchAlarms` (debt #30) in a second
    apply, after the first real alarm proves the path.
- **Expected `PublishIn.AuthError` false positives.** The metric is
  account-wide, so another MQTT client in the account would page.
- **Demo email volume.** In demo, the ops inbox receives a few silence
  emails per cycle.

## Revisit triggers

- A second operator or a non-email channel: revisit `ok_actions` and grouping.
- Real sensor cadence known: set `telemetry_silence_minutes` from it (owner assigned).
- More than one MQTT workload in the account: scope or drop `iot-publish-auth-errors`.
- A rule error that the metrics cannot explain: enable IoT logging temporarily and record it.
- Production traffic with `Duration` p99 above 30 % of the timeout: add a `Duration` alarm and revisit ADR-0011.
- Any automated redrive or replay: supersedes D4.

## References

- Provider `aws_cloudwatch_metric_alarm`, `aws_cloudwatch_log_metric_filter`, `aws_cloudwatch_composite_alarm`, `aws_cloudwatch_dashboard`, `aws_iot_logging_options` (provider `main`, CHANGELOG head 6.68.0, 2026-10-07): https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/
- CloudWatch missing-data treatment: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/alarms-and-missing-data.html
- PutMetricAlarm limits: https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_PutMetricAlarm.html
- SetAlarmState: https://docs.aws.amazon.com/cli/latest/reference/cloudwatch/set-alarm-state.html
- SQS metrics and inactive queues: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-available-cloudwatch-metrics.html, https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/monitoring-using-cloudwatch.html
- AWS IoT metrics: https://docs.aws.amazon.com/iot/latest/developerguide/metrics_dimensions.html
- IoT rule error handling: https://docs.aws.amazon.com/iot/latest/developerguide/rule-error-handling.html
- IoT logging: https://docs.aws.amazon.com/iot/latest/developerguide/configure-logging.html
- Lambda metrics: https://docs.aws.amazon.com/lambda/latest/dg/monitoring-metrics-types.html
- SNS metrics: https://docs.aws.amazon.com/sns/latest/dg/sns-monitoring-using-cloudwatch.html
- SNS key management (service principals): https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html
- CloudWatch → SNS topic policy: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Notify_Users_Alarm_Changes.html
- Filter pattern syntax: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html
- CloudWatch pricing: https://aws.amazon.com/cloudwatch/pricing/
