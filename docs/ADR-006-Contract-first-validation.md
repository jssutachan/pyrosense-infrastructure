# ADR — Contract-first re-validation at the consumer boundary

> **Number:** assign the next in your `docs/` sequence.
> **Status:** Accepted · 2026-09-21
> **Scope:** ingest core (`contract.py`)

## Context

The simulator publishes telemetry as JSON. IoT Core routes it without inspecting
it; SQS transports it as opaque bytes. The first — and only — point where any
component can ask "is this message valid?" is the ingest Lambda. The producer and
consumer are developed independently and evolve separately.

## Decision

Re-validate every message against a **frozen contract v1** at the consumer
boundary, before any processing, even though the producer is our own simulator.
Validation:

- is a **closed set** — unknown fields are rejected, not ignored;
- checks required keys, types, ranges, identifier patterns, the status enum, and
  a timezone-aware timestamp;
- **accumulates all violations** and raises once, so a single log line explains
  the full mismatch;
- returns an **immutable, typed `TelemetryRecord`** — the trust boundary: raw
  dict in, trusted object out.

A contract violation is a **permanent** failure and is routed to the DLQ; it is
never retried.

## Rationale

*"Don't trust the producer, even when the producer is you."* The queue boundary
is exactly where integration bugs and malformed/spoofed messages surface. A
closed set means a new, undeclared field is caught immediately rather than
silently dropped. Accumulating errors makes the 3 a.m. log actionable in one read.

## Alternatives considered

- **Trust the simulator, skip validation** → **rejected**: couples consumer
  correctness to producer discipline; any drift becomes a silent corruption.
- **Validate but coerce/repair** (e.g. clamp out-of-range values) → **rejected**:
  hides producer bugs and fabricates data; better to reject and preserve evidence.
- **Fail on first error** → **rejected**: forces fix-retry-fix cycles; batching
  all errors is cheaper to debug.

## Consequences

- **Positive:** corruption is stopped at the door; the rest of the pipeline works
  with a trusted, typed object; broken producers surface in the DLQ as evidence.
- **Negative / follow-up:** the contract is a shared artifact — producer and
  consumer must evolve it together (versioned via `schema_version`).
