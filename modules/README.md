# Terraform Modules

Reusable Terraform modules composed by the root configuration.

## Conventions

- One directory per module, named after the capability it provides
  (e.g. `ingestion/`, `alerting/`), not after the AWS service it wraps.
- Every module declares its own `versions.tf` with `required_version` and
  `required_providers`. TFLint enforces this per module, not only at the root.
- Standard file layout: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`.
- Modules never declare a `provider` block. Providers are configured at the
  root and inherited.
- Every variable has a `description` and an explicit `type`.

## Not here

Environment-specific values. Modules expose variables; the root passes them
from the corresponding `.tfvars` file.
