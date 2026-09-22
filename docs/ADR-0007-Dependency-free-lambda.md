# ADR 0007 — Dependency-free Lambda (standard library only)

> **Number:** assign the next in your `docs/` sequence.
> **Status:** Accepted · 2026-09-21
> **Scope:** ingest core packaging (`src/ingest_lambda/`, `pyproject.toml`)

## Context

The ingest Lambda needs JSON parsing, datetime handling, logging, and calls to
DynamoDB, S3 and SNS. The AWS Lambda Python 3.12 runtime already ships `boto3`.
Third-party packages can be vendored into the deployment zip, but each adds size,
cold-start weight, and CVE surface to patch.

## Decision

Ship the Lambda with **zero runtime dependencies**: standard library only, and
use the `boto3` provided by the runtime (never vendored). `pyproject.toml`
declares `dependencies = []`. All tooling (pytest, moto, ruff, mypy) lives in
`requirements-dev.txt` and is **development-time only** — never in the zip.

## Rationale

- Smallest possible artifact and cold start; nothing to patch for third-party CVEs.
- The zip is exactly the `src/ingest_lambda/` folder, produced at deploy time by
  Terraform `archive_file` — reproducible, no build step, no lockfile drift.
- Forces the logic to stay simple and portable (validation, risk, EMF and
  structured logging are all achievable with the stdlib).

## Alternatives considered

- **Vendor `pydantic` for validation** → **rejected**: heavier artifact and a
  dependency to track, for validation the stdlib handles at this scale.
- **AWS Lambda Powertools (Idempotency, Logger, Metrics)** → **rejected for now**:
  excellent library, but pulling it in for a portfolio MVP hides the mechanics
  this project exists to demonstrate. Revisit if the function grows.
- **Pin `boto3` in the zip** → **rejected**: duplicates what the runtime provides
  and risks version skew with the managed SDK.

## Consequences

- **Positive:** minimal size/cold-start/CVE surface; trivial packaging; the code
  demonstrates the patterns explicitly.
- **Negative / follow-up:** we reimplement small pieces (idempotency, structured
  logs) that a library would provide — an accepted trade-off, documented here so
  the choice is deliberate, not accidental.
