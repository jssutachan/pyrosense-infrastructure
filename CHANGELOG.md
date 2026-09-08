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

### Changed

- Re-enabled the `terraform_unused_required_providers` TFLint rule now that
  the root module declares an `aws_*` resource.
- Tag-linting strategy: replaced `aws_resource_missing_tags` with
  `aws_provider_missing_default_tags`, which validates the provider's
  `default_tags` where TFLint can read it, instead of each resource across
  the module boundary. (ADR-0004)

### Security

- Backend configuration is excluded from version control: the state bucket
  name carries the AWS account ID as a suffix.
- Real `*.tfvars` files are gitignored (they carry operator email
  addresses); only `*.tfvars.example` templates are committed.
