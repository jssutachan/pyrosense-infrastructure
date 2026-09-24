# ADR-0004 — Lint tags at the provider, not per resource

**Status:** Accepted

## Context

Tagging is enforced through the root provider's `default_tags`
(`Project` / `Environment` / `ManagedBy`), inherited by every resource. The
TFLint rule `aws_resource_missing_tags` checks each resource for those tags —
but it evaluates each module in isolation, and `default_tags` lives in the
root provider, not the child module. TFLint cannot follow `default_tags`
across the module boundary, so it reports a false positive on every resource
in every module. With eight modules planned, all inheriting the same
`default_tags`, this would recur indefinitely.

## Decision

Disable `aws_resource_missing_tags` and enable
`aws_provider_missing_default_tags` with the same required keys. This rule
verifies that each `provider "aws"` block declares `default_tags` with those
keys, and runs where the provider is defined (root and bootstrap) — exactly
where TFLint can read it. Child modules define no provider, so the rule emits
nothing there. The tag contract is verified once, at its source, instead of
unverifiably at every resource.

## Consequences

- No per-resource `tflint-ignore` pragmas; module code stays clean, and the
  fix covers all eight modules from a single config change.
- The rule also validates the bootstrap provider, catching any tag-key drift
  (e.g. a stray `Env` instead of `Environment`).
- **Trade-off:** the rule no longer detects a resource that overrides its own
  tags and omits a required key. Acceptable under a pure `default_tags`
  strategy where no resource sets tags directly. A future module needing
  per-resource tags would reintroduce `aws_resource_missing_tags` scoped to
  that module only.

## Alternatives considered

- **Per-resource `tflint-ignore`** — rejected: silences the symptom, repeats
  on every resource of every module, does not scale.
- **Literal `tags` on each resource** — rejected: duplicates `default_tags`;
  identical keys in both trigger a provider error or a perpetual diff.
- **Disabling tag linting entirely** — rejected: loses all enforcement of the
  tag contract.
