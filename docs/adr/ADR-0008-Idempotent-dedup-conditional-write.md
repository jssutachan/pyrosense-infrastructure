# ADR 0008 — At-least-once delivery handled by idempotent conditional writes

> **Number:** assign the next in your `docs/` sequence.
> **Status:** Accepted · 2026-09-21
> **Scope:** ingest core (`src/ingest_lambda/`)

## Context

Telemetry reaches the ingest Lambda over MQTT (IoT Core, QoS 1) and Amazon SQS
standard queues. Both provide **at-least-once** delivery: the *same* message can
be delivered more than once (broker re-delivery, visibility-timeout races, device
reconnects replaying old readings). This is a guarantee of those transports, not
a bug. Exactly-once delivery does not exist in distributed systems; it must be
*simulated* by making processing idempotent.

The Lambda also runs at concurrency > 1: many container instances process
messages for the same device simultaneously, with no shared memory.

## Decision

Make each write **idempotent by construction**, keyed by the natural identity of
a reading (`device_id` + `seq`):

- **Hot store (DynamoDB):** `put_item` with `ConditionExpression =
  attribute_not_exists(pk)`. The first delivery wins; a duplicate fails the
  condition and is counted as `DuplicatesSkipped` — no error raised.
- **Cold store (S3):** a **deterministic key** derived from `device_id` + `seq`;
  a re-delivery overwrites itself with identical bytes.
- The dedup write is the **last** step of the pipeline, so a crash mid-message
  replays every prior (idempotent) step safely.

## Rationale

- The write **is** the dedup guard — no separate "seen messages" store, no lock,
  no in-memory cache. Correct even with many concurrent Lambda instances, because
  DynamoDB resolves the race atomically inside a single conditional write.
- One item per reading tolerates **out-of-order** delivery (SQS standard does not
  preserve order): each `seq` has its own row, so arrival order is irrelevant.

## Alternatives considered

- **`last_seq` high-water mark** (`seq > last_seq`) → **rejected**: with
  reordering, a message that arrives after a higher `seq` would be discarded as
  "old" — silent data loss.
- **In-memory / shared cache of seen ids** → **rejected**: container memory is
  not shared and is recycled without notice; a shared cache still leaves a
  non-atomic read-then-write race window.
- **FIFO queues with exactly-once** → **rejected**: throughput limits and cost;
  idempotency is the portable, transport-agnostic solution.

## Consequences

- **Positive:** no message loss under burst/duplicate/reorder; no coordination
  primitives; trivially unit-testable.
- **Negative / follow-up:** requires DynamoDB **TTL enabled** on `expires_at`
  (infra concern) so hot items expire; the cold store keeps the permanent history.
- Related: alert de-duplication is handled separately (see the alert-suppression ADR).
