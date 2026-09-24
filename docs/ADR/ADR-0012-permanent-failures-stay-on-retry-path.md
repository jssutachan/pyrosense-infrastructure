# ADR-0012 — Permanent (contract) failures stay on the SQS retry path

- **Status:** Accepted
- **Date:** 2026-09-22
- **Scope:** `src/ingest_lambda/handler.py`, `modules/messaging`, future `modules/observability`
- **Related:** ADR-0006, ADR-0008, ADR-0009, ADR-0011

## Context

The ingest handler classifies failures in two classes (`test_error_paths.py`):

- **Permanent:** `ContractViolationError`, including a body that is not valid
  JSON. The outcome depends only on the payload bytes; no retry can fix it.
- **Transient:** any other exception (throttling, permissions, networking).

SQS does not know this distinction; it only counts `ReceiveCount`. Today the
handler reports **both** classes in `batchItemFailures`, so a contract
violation is retried until `maxReceiveCount` (5, ADR-0011) and then moved to
the DLQ.

Three options were evaluated:

- **(a)** Keep permanent failures on the retry path (current behavior).
- **(b)** Quarantine: write the rejected payload to an S3 `quarantine/`
  prefix, emit a metric, and acknowledge the message so SQS deletes it. Only
  transient failures reach the DLQ.
- **(c)** The handler sends permanent failures to the DLQ itself
  (`SendMessage`) and acknowledges them.

The producer is currently our own simulator; contract violations are expected
to be rare and to indicate a producer bug.

## Decision

**(a)**: permanent failures stay on the retry path. The handler keeps
reporting them in `batchItemFailures`; after 5 receives SQS moves them to the
DLQ. No code change.

## Rationale

- **One triage path.** Everything that failed ends up in one place, with the
  payload intact and SQS-set attribution (`DeadLetterQueueSourceArn`).
- **No new failure mode.** (b) makes deletion depend on a successful S3 write
  and adds a second evidence store; (a) never deletes a message it could not
  process.
- **Proportional cost.** With a self-owned simulator, the expected poison
  volume is near zero; 4 extra invocations per broken message are not
  measurable against the budget.
- **Tested code stays untouched.** The handler (91 tests) already implements
  (a); (b) would change the handler, the storage lifecycle, and the ingest IAM
  policy for a benefit not yet observed.

## Alternatives considered

| Alternative | Why it was rejected (for now) |
|---|---|
| (b) Quarantine in S3 | Separates the signals and saves invocations, but adds a handler branch, an S3 prefix with its own lifecycle, IAM scope, and a delete-after-write invariant. Justified only when poison volume is real |
| (c) Handler sends to the DLQ directly | Needs `sqs:SendMessage` and `kms:GenerateDataKey` on the DLQ for the Lambda role, bypasses the redrive mechanism, and still mixes both failure classes in the DLQ |
| Lower `maxReceiveCount` (e.g. 1–2) | Reduces waste on poison messages but sends transient failures to the DLQ on their first hiccup; ADR-0011 keeps 5 |

## Consequences

- **The DLQ mixes two classes:** transient failures that exhausted retries
  (safe to redrive) and contract violations (will fail again).
  **Operating rule: never redrive the DLQ blindly.** Before a redrive
  (`StartMessageMoveTask`), re-validate the DLQ payloads against the contract
  and redrive only the ones that pass.
- **Wasted work:** each contract violation costs 5 invocations and, with a
  180 s visibility timeout (ADR-0011), stays in the source queue for several
  minutes before reaching the DLQ. It does not block other messages: the
  queue is standard.
- **Metric semantics:** the `InvalidPayloads` EMF metric is incremented on
  **every** attempt, so one broken message emits it 5 times. The count of
  unique broken messages is the DLQ depth, not this metric;
  `modules/observability` must alarm accordingly.
- `modules/storage` needs no `quarantine/` prefix.

## Revisit triggers

- A producer we do not control (physical sensors, a third party) starts
  publishing, making contract violations a normal occurrence rather than a
  bug signal.
- Contract violations appear in the DLQ in any week of normal operation, or
  a redrive is attempted and fails because of mixed contents.
- Automated redrive becomes a requirement: it needs a DLQ with only
  redrive-safe messages, which is option (b).
- Wasted invocations become visible in the Lambda cost line of the budget.

## References

- Amazon SQS dead-letter queues and redrive: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
- ReceiveMessage `DeadLetterQueueSourceArn` attribute: https://docs.aws.amazon.com/cli/latest/reference/sqs/receive-message.html
- Lambda — SQS partial batch responses: https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html
