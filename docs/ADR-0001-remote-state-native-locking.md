# ADR-0001 — Remote state on S3 with native lockfile locking

**Status:** Accepted

## Context

Terraform state is the source of truth for every deployed resource.
Local state cannot be shared, reviewed or recovered; concurrent runs
without locking corrupt it. Historically S3 backends paired with a
DynamoDB table for locking, but Terraform 1.10+ ships native S3
lockfile support and deprecates the DynamoDB path.

## Decision

State lives in a dedicated, versioned, encrypted S3 bucket (created by
`bootstrap/state-backend`). The backend uses `use_lockfile = true`;
account-specific values are injected through a gitignored
`config/backend.hcl`, keeping the codebase free of account ids. The
project pins `required_version >= 1.11`.

## Consequences

- One less resource (and cost) to manage; locking has no DynamoDB table
  to misconfigure.
- Recovery from a bad state push is a bucket-version rollback.
- The bootstrap stack itself keeps local state (chicken-and-egg),
  documented in its header.

## Alternatives considered

- **DynamoDB locking** — deprecated since 1.11; rejected.
- **Terraform Cloud** — free tier viable but adds a SaaS dependency the
  portfolio does not need to demonstrate.
