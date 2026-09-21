# Ingest Lambda — PyroSense ingest core

The **only place in PyroSense with business logic.** Everything around it
(IoT Core, SQS, DynamoDB, S3, SNS) transports, stores or notifies; this
function *decides*. For each telemetry message delivered by SQS it:

1. **Validates** the frozen telemetry contract v1 (`contract.py`).
2. **Classifies** fire risk — the decision the sensor never makes (`risk.py`).
3. **Archives** the raw body in S3, idempotent by key (`cold_store.py`).
4. On **CRITICAL** risk, publishes an alert guarded by a per-device
   suppression window (`alerts.py`).
5. **Inserts** the hot item in DynamoDB; the conditional write doubles as the
   at-least-once **deduplication** guard (`persistence.py`).

Every step is idempotent or condition-guarded, so a crash mid-message is safely
replayed by SQS.

---

## Modules

| File                    | Layer        | Responsibility |
| ----------------------- | ------------ | -------------- |
| `config.py`             | config       | `Settings` loaded & frozen from env vars; fail-fast at cold start |
| `contract.py`           | pure         | Contract v1 validation → immutable `TelemetryRecord` |
| `risk.py`               | pure         | Risk classification `NONE` / `ELEVATED` / `CRITICAL` with reasons |
| `metrics.py`            | pure         | CloudWatch EMF metrics (one JSON line on **stdout**) |
| `structured_logging.py` | pure         | JSON logs on **stderr**, whitelisted context fields |
| `cold_store.py`         | effect (S3)  | Raw copy to S3, Hive-partitioned deterministic key |
| `persistence.py`        | effect (DDB) | Hot item write; conditional-write dedup; TTL; `Decimal` coercion |
| `alerts.py`             | effect (DDB+SNS) | Race-free suppression slot + self-contained SNS alert |
| `handler.py`            | orchestration | Batch loop, error classification, partial batch responses |

---

## Design invariants

- **No runtime dependencies.** The deployment zip is standard-library only;
  `boto3` is provided by the AWS Lambda runtime and is never vendored.
- **Config in the environment.** No ARNs, table names or thresholds are
  hardcoded — Terraform injects them; `config.py` reads and freezes them.
- **Two output channels.** Logs are JSON on **stderr**; EMF metrics on
  **stdout**. Keep the Lambda log format at `Text` so the runtime does not wrap
  the EMF documents.
- **Idempotent by construction.** The dedup put is the *last* step, so a crash
  mid-message replays safely (S3 key is deterministic, alerts are suppression-
  guarded, the hot write is conditional).
- **Don't trust the producer.** The consumer re-validates at the queue boundary —
  exactly where integration bugs and malformed messages surface.

---

## How it's imported

The modules are **flat** (no package): `handler.py` does `from contract import …`,
exactly as they sit at the root of the deployment zip. The test suite reproduces
this by putting `src/ingest_lambda` on the import path
(`pythonpath` in `pyproject.toml`), so tests import the modules the same way the
Lambda runtime does.

---

## Packaging

This directory is zipped as-is at deploy time by Terraform (`archive_file`) — you
never build the zip by hand. Keep the `.py` files plain and dependency-free.

Runtime: **Python 3.12**, arm64.

---

## Tests

The suite lives in `../../tests/`. From the repository root:

```bash
pytest                 # runs everything against in-memory AWS (moto)
```

See `tests/README.md` for details.
