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


The state bucket is encrypted with SSE-S3 (`AES256`), not a
customer-managed KMS key (CMK). Two reasons drive this:

1. **Bootstrap ordering.** The bootstrap stack runs before any project
   CMK exists. Encrypting its own state bucket with a CMK would create a
   second chicken-and-egg dependency on top of the state one.
2. **Failure mode.** If state were encrypted with a CMK and that key were
   ever scheduled for deletion or lost access, the state — the map of all
   deployed infrastructure — would become unreadable. SSE-S3 has no such
   failure mode; the key is always managed and present.

SSE-KMS with a CMK would add key-level access control, CloudTrail
auditing of key usage, and managed rotation. For a state bucket that only
Terraform touches, that is over-engineering with a dangerous failure mode.
A high-compliance context (e.g. regulated state) would revisit this and
accept CMK management in exchange for those controls.

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
- **SSE-KMS with a CMK** — rejected for the bootstrap: adds a second
  circular dependency and a catastrophic failure mode (unreadable state
  if the key is lost). Revisit for high-compliance environments.
