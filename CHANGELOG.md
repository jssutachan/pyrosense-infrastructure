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

### Security

- Backend configuration is excluded from version control: the state bucket name
  carries the AWS account ID as a suffix.
