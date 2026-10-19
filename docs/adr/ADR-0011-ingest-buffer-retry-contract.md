# ADR-0011 — Ingest buffer retry contract: consumer-derived visibility timeout and a DLQ that outlives its source

- **Status:** Accepted
- **Date:** 2026-09-22
- **Scope:** `modules/messaging`, root module locals, future `modules/ingest`
- **Related:** ADR-0002, ADR-0008, ADR-0010

## Context

`modules/messaging` provides the buffer between AWS IoT Core and the ingest
Lambda: a standard SQS queue plus a dead-letter queue (DLQ). The queue is
standard because the IoT Core SQS rule action does not support FIFO queues;
ordering is not needed because persistence is idempotent (ADR-0008).

Three queue parameters decide whether retries behave correctly, and none of
them is safe to leave as a free number:

1. **Visibility timeout.** AWS Lambda guidance for SQS event sources is a
   visibility timeout of at least 6x the function timeout, plus the event
   source mapping's batching window. The headroom lets Lambda retry a batch
   it could not invoke because the function was throttled. If the timeout is
   shorter, a message reappears to a second poller while the first batch is
   still in flight: it is processed twice and its `ReceiveCount` climbs
   without any handler failure, which can push healthy messages into the DLQ.
   Lambda itself only rejects an event source mapping whose function timeout
   exceeds the visibility timeout; the 6x rule is not enforced by AWS.
2. **Retention.** For standard queues, a message keeps its original enqueue
   timestamp when it moves to the DLQ. A DLQ whose retention is equal to or
   shorter than the source's can delete a message soon after it arrives,
   silently destroying the evidence the DLQ exists to keep.
3. **Redrive permissions.** A DLQ's redrive allow policy defaults to
   `allowAll`: any queue in the same account and Region can target it.

The value that drives (1), the Lambda timeout, belongs to a module that does
not exist yet (`modules/ingest`), and no Duration measurements exist.

## Decision

1. **The visibility timeout is derived, not configured.**
   `modules/messaging` takes `consumer_timeout_seconds` and
   `consumer_batching_window_seconds` as inputs and computes
   `visibility_timeout = 6 × timeout + batching_window`. Both values live
   once, as root-module locals (`ingest_lambda_timeout_seconds = 30`,
   `ingest_batching_window_seconds = 0`), and will be passed to both
   `messaging` and `ingest`. They are locals rather than root variables
   because they do not differ between demo and production (ADR-0002).
2. **The DLQ outlives its source.** Source retention is 4 days; DLQ retention
   is 14 days, the service maximum. A `precondition` on the DLQ fails the plan
   if a future edit breaks `dlq_retention > source_retention`.
3. **`maxReceiveCount = 5`**, the minimum AWS recommends for Lambda consumers.
4. **The redrive contract is enforced on both sides:** a redrive policy on the
   source queue, and a `byQueue` redrive allow policy on the DLQ naming only
   the ingest queue.

Retention and `maxReceiveCount` are module locals, not inputs: they are design
constants, identical in every environment.

## Rationale

- Deriving the visibility timeout removes a class of error rather than
  detecting it: no tfvars value can produce a timeout that violates the
  guideline, and the queue and its consumer read the same source of truth.
- Keeping the shared values in the root puts them in the composition layer,
  the only place that sees both modules. It does not make `messaging` depend
  on a module that has not been written.
- With the retention precondition, a guarantee that used to be implicit is
  now checked mechanically at plan time.
- `byQueue` keeps the DLQ's contents attributable to a single source, so a
  redrive returns messages to the queue they came from.

## Alternatives considered

| Alternative | Why it was rejected |
|---|---|
| Visibility timeout as a module input, with a cross-variable validation (Terraform >= 1.9) | Still a human-typed number that must be kept in step with another number. Validation only detects the error; derivation prevents it |
| `modules/ingest` outputs its timeout and `messaging` consumes it | Couples `messaging` to a module that does not exist yet, and hides a shared setting inside one of its two consumers. The root is already the composition point |
| AWS default retention on both queues (4 days) | DLQ = source retention allows early expiry of messages in the DLQ, and loses them without a trace |
| AWS default `maxReceiveCount` (10), or 1 | 10 doubles the wasted invocations per poison message; 1 sends a message to the DLQ on its first transient failure |
| Leave the redrive allow policy at `allowAll` | Any queue in the account and Region could mix unrelated failures into PyroSense triage |
| FIFO queue | Not supported by the IoT Core SQS rule action |

## Consequences

- **Alert latency cost.** A message reported as failed becomes visible again
  only after the visibility timeout expires. At a 30 s function timeout, each
  transient retry waits 180 s, and a message can take several such cycles
  before reaching the DLQ. For a wildfire-alerting path this is the main cost
  of the decision. A handler-side backoff (`ChangeMessageVisibility`) could
  shorten it, but that is deferred: it adds an IAM permission and logic
  without measured need.
- **Constraint on `modules/ingest`:** with a batching window of 0, the event
  source mapping's batch size must stay at or below 10 (AWS requires a window
  of at least 1 s for larger batches).
- **Retention ceiling:** because the DLQ already uses the 14-day maximum, the
  source retention can never exceed 14 days minus the desired triage window.
- **The 30 s timeout is provisional**, chosen without Duration data.
- - **Permanent (contract) failures also consume all 5 attempts** and land in
  the DLQ next to redrive-safe transient failures. ADR-0012 accepts that
  trade-off and sets the rule: never redrive the DLQ blindly.
- Renaming or restructuring these parameters now touches two modules and the
  root; a queue-only change is no longer self-contained.

## Revisit triggers

- `modules/ingest` is deployed and its measured p99 `Duration` makes the 30 s
  timeout clearly oversized or undersized.
- An alert-latency objective is defined and `6 × timeout` per retry exceeds
  it; that reopens the handler-side backoff option.
- The event source mapping needs a batch size above 10, forcing a non-zero
  batching window.
- A second consumer is attached to the ingest queue, breaking the
  one-queue/one-consumer assumption behind the derivation.
- ADR-0012 is revisited and permanent failures leave the retry path, which
  may change `maxReceiveCount`.

## References

- Lambda — configuring an SQS event source: https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html
- Amazon SQS dead-letter queues (retention and redrive allow policy): https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
- SetQueueAttributes (valid ranges, `redrivePermission` values): https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_SetQueueAttributes.html
- AWS IoT SQS rule action (no FIFO support): https://docs.aws.amazon.com/iot/latest/developerguide/sqs-rule-action.html
