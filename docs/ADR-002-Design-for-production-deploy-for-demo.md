# ADR-0002 — Design for production, deploy for demo

**Status:** Accepted

## Context

PyroSense is a portfolio project. Its value is demonstrating
production-grade architecture, but it runs in a free-tier AWS account that
cannot spend real money and must stay at `$0`. These goals pull opposite
ways: production realism implies scale and cost; the demo constraint
implies the smallest possible footprint.

A naive resolution — building a simplified "demo version" of each
component — would defeat the purpose: the artifact reviewers judge would no
longer be the production design.

## Decision

The codebase is written **once, for production**. What differs between
production and the demo deployment is isolated entirely in per-environment
`*.tfvars` files consumed by root-level variables. Architecture, module
structure, and resource definitions are identical across environments;
only scale-and-scenario values change.

- `environment` (`demo` | `prod`) drives naming and `default_tags`.
- `demo.tfvars` / `prod.tfvars` carry only values that legitimately differ;
  everything else uses module defaults.
- Only `*.tfvars.example` templates are committed; real files are gitignored.
- The project deploys `demo` exclusively. `prod` values exist as a
  documented design target, never applied.

## Consequences

- Reviewers read one production-grade codebase, not a toy.
- The demo/prod difference is auditable at a glance — the diff between two
  small tfvars files.
- Every component must justify its place in a *production* design. A feature
  that only makes sense in the demo account is a signal it does not belong
  (see ADR-0003, the rejected credit-runway budget).
- The demo deployment exercises the real code path, so "works in demo" is
  meaningful evidence the production design is sound.

## Alternatives considered

- **A separate simplified demo stack** — rejected: the demo would no longer
  demonstrate the production architecture, defeating the project's purpose.
- **Hardcoding demo values** — rejected: couples the code to one scenario
  and erases production intent.
- **Terraform workspaces** — deferred: viable for environment separation,
  but tfvars files are more explicit and visible for a portfolio, where the
  difference itself is part of what is demonstrated.
