# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository scaffolding: directory structure, editor configuration and license.
- Terraform version contract pinning Terraform >= 1.11 and the AWS provider 6.x.
- Quality gate: TFLint with the AWS and Terraform rulesets, Trivy for
  misconfiguration scanning, Gitleaks for secret detection, and Ruff, mypy and
  pytest for Python.
- `pre-commit` configuration running the gate locally before every commit.
- `Makefile` as the single entry point for the gate and Terraform operations.
- Architecture Decision Record framework under `docs/adr/`.
- `config/backend.hcl.example` documenting the partial backend configuration.
- Remote state backend (`bootstrap/state-backend`): a versioned, SSE-S3
  encrypted, TLS-only S3 bucket with native lockfile locking and 90-day
  noncurrent-version expiry. (ADR-0001)
- Root module composition: the `budgets` module wiring, root inputs
  (`resource_prefix`, `budget_limit_usd`, `ops_emails`), a `name_prefix`
  local, and a re-exported `budget_arn` output.
- `modules/budgets`: account-wide monthly cost budget (FinOps guardrail).
  ACTUAL and FORECASTED email alerts; measures gross consumption
  (`include_credit = false`) so free-tier credits do not mask spend.
  Monitoring-only, `$0` cost. (ADR-0003)
- `demo.tfvars.example` / `prod.tfvars.example` templates for the two
  deployment scenarios. (ADR-0002)
- Ingest core Lambda (`src/ingest_lambda/`, Python 3.12): the only component
  with business logic. Nine standard-library-only modules —
  `config` (env-driven `Settings`, fail-fast), `contract` (frozen contract v1
  validation → immutable `TelemetryRecord`), `risk` (pure fire-risk
  classification with explainable reasons), `persistence` (DynamoDB hot write,
  conditional-write dedup, TTL), `cold_store` (raw S3 archive, Hive-partitioned
  deterministic key), `alerts` (SNS publish with race-free per-device
  suppression), `metrics` (CloudWatch EMF on stdout), `structured_logging`
  (JSON logs on stderr, whitelisted context fields) and `handler`
  (SQS batch orchestration with partial batch responses). No runtime
  dependencies; `boto3` is provided by the Lambda runtime.
  (ADR-0005, ADR-0006, ADR-0007, ADR-0008, ADR-0009)
- Test suite (`tests/`): 91 pytest tests, ~99% branch coverage, running against
  an in-memory AWS (moto) — no account, no credentials, no cost. `conftest.py`
  provisions a fresh DynamoDB/S3/SNS stack per test and wires an SQS queue to
  the SNS topic to assert on published alerts. Includes regression tests for the
  three correctness bugs found in review and transient-vs-permanent error-path
  coverage.
- Python tooling in `pyproject.toml`: coverage configuration with a 90% branch
  gate (`[tool.coverage.*]`), alongside the existing Ruff/mypy/pytest config.
- `requirements-dev.txt`: development-only tooling (never shipped in the Lambda
  zip), version-pinned with compatible-release specifiers.
- CI pipeline (`.github/workflows/ci.yml`, GitHub Actions): runs the Python
  quality gate (Ruff lint + format, mypy, pytest with coverage) on every push
  and pull request that touches the Lambda. Least-privilege `contents: read`,
  concurrency cancel-in-progress, path-filtered to the Python project, and
  pinned to Python 3.12 to match the runtime.
- Component documentation: `src/ingest_lambda/README.md` (modules, design
  invariants, packaging) and `tests/README.md` (how to run, fixtures,
  conventions).
- ADR-0005 — Contract-first re-validation at the consumer boundary.
- ADR-0006 — At-least-once delivery handled by idempotent conditional writes.
- ADR-0007 — Dependency-free Lambda (standard library only).
- ADR-0008 — Observability: JSON logs on stderr, EMF metrics on stdout.
- ADR-0009 — Alert suppression: race-free slot, claimed before publishing.

### Changed

- Re-enabled the `terraform_unused_required_providers` TFLint rule now that
  the root module declares an `aws_*` resource.
- Tag-linting strategy: replaced `aws_resource_missing_tags` with
  `aws_provider_missing_default_tags`, which validates the provider's
  `default_tags` where TFLint can read it, instead of each resource across
  the module boundary. (ADR-0004)
- Root `README.md`: corrected the repository structure to match the actual
  layout, added the SQS buffer to the reference architecture diagram, aligned
  the ADR list and quality gate, and added a Python test quickstart (requires
  Python 3.12).

### Fixed

- `contract` validation, from senior review of the AI-drafted ingest core:
  reject non-finite numbers (`NaN`/`Infinity` previously slipped past range
  checks); a non-hashable `status` now raises `ContractViolationError` instead
  of an unclassified `TypeError`; identifier patterns use `re.fullmatch` so a
  trailing newline can no longer pass. `config` now names the offending
  environment variable when a numeric value fails to parse.

### Security

- Backend configuration is excluded from version control: the state bucket
  name carries the AWS account ID as a suffix.
- Real `*.tfvars` files are gitignored (they carry operator email
  addresses); only `*.tfvars.example` templates are committed.
- CI runs with least-privilege permissions (`contents: read` only) and never
  vendors third-party packages into the Lambda deployment artifact, keeping the
  runtime CVE surface minimal.
