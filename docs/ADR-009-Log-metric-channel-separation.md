# ADR — Observability: JSON logs on stderr, EMF metrics on stdout

> **Number:** assign the next in your `docs/` sequence.
> **Status:** Accepted · 2026-09-21
> **Scope:** ingest core (`structured_logging.py`, `metrics.py`)

## Context

The Lambda emits two kinds of observability output: **metrics** (batch outcome
counters) and **logs** (diagnostics). Metrics use CloudWatch Embedded Metric
Format (EMF) — a structured JSON line on **stdout** that CloudWatch turns into
metrics with no API call, no extra IAM, no hot-path latency. Logs should be
queryable by field in CloudWatch Logs Insights, which means structured JSON too.

The risk: if both went to the same channel, or if the Lambda runtime's own JSON
log format wrapped the EMF documents, CloudWatch could no longer distinguish a
metric document from a log line — **silently breaking metric extraction**.

## Decision

Keep two channels with no collision:

- **Metrics (EMF): stdout** — `metrics.py` prints one EMF document per invocation.
- **Logs (JSON): stderr** — `structured_logging.py` installs a JSON formatter
  bound explicitly to stderr, with a **whitelist** of context fields
  (`device_id`, `seq`, `message_id`, `errors`, `reasons`).
- Keep the Lambda **log format at `Text`** (not the runtime's native JSON) so it
  does not re-wrap the EMF on stdout.
- An unknown log level degrades to `INFO` instead of raising: an observability
  typo must never stop fire detection.

## Rationale

- Separation of channels is what keeps metrics extractable while logs stay
  queryable. It is the Well-Architected Operational Excellence pillar applied to
  the two output streams.
- The field whitelist is a **security boundary**: telemetry carries device
  coordinates, so a careless `extra=` cannot leak payload data into logs.
- Stdlib-only (`logging` + `json`) keeps the dependency-free packaging intact.

## Alternatives considered

- **Enable the runtime's native JSON log format** → **rejected**: it would wrap
  the EMF stdout documents and break metric extraction.
- **`PutMetricData` API calls for metrics** → **rejected**: adds latency, IAM
  permissions and cost on the hot path; EMF is free and asynchronous.
- **Open field logging (no whitelist)** → **rejected**: risk of leaking device
  location into logs.

## Consequences

- **Positive:** queryable structured logs + zero-cost metrics, no cross-talk; no
  extra IAM; no hot-path latency.
- **Negative / follow-up:** the infra must **not** turn on the Lambda native JSON
  log format; document this in the ingest Terraform module (`log_format = Text`).
