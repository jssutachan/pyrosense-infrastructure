# ADR-0003 — Account-wide monthly budget as the FinOps guardrail

**Status:** Accepted

## Context

The demo account runs on free-tier credits ($200 / 6 months) and must never
incur real charges. A cost guardrail is the third line of FinOps defense
(after tagging and finite retention) and the first one installed, because it
protects everything deployed afterward.

Three design questions arose: what scope to measure, whether to count
credits, and whether a second budget tracking credit runway was worth
building.

## Decision

**A single account-wide monthly cost budget** with ACTUAL and FORECASTED
email notifications. No budget actions (monitoring only), so cost is `$0`.

1. **Account-wide, not tag-scoped.** A budget filtered by `Project=PyroSense`
   cannot see untagged resources — precisely the mistake a guardrail exists
   to catch. Tag-scoped budgets also require activating cost-allocation tags
   by hand in the billing console (clickops), which this repository forbids.
2. **Credits excluded (`include_credit = false`).** AWS defaults this to
   `true`, netting credits against spend: under credits the budget reads
   ~`$0` and never fires until the grant is gone. Excluding them measures
   **gross consumption** — the number that reveals a runaway resource while
   credits still cover it.
3. **One budget, not two.** An earlier draft added a `credit-runway` budget
   tracking cumulative spend against the grant. It was cut: a "how much of my
   free-tier grant is left?" budget only makes sense in a learning account,
   which violates ADR-0002. AWS also sends native credit-balance alerts for
   the demo case, making it redundant.

## Consequences

- The guardrail catches cost from any resource, tagged or not.
- Under credits, the budget still reports real usage, so alerts fire when
  they should.
- The module stays a single-resource template — the simplest building block
  for the modules that follow.
- No automated cost *enforcement* (the budget only notifies). The operating
  model (*turn on, demonstrate, destroy*) plus finite retention cover the
  gap, since budget data refreshes only every ~8–12h.

## Alternatives considered

- **Tag-scoped budget** — rejected: blind to untagged resources and requires
  clickops to enable.
- **`include_credit = true`** — rejected for the demo: silent while credits
  last. It is the correct setting once the account pays its own way.
- **Second credit-runway budget** — rejected: demo-only artifact (violates
  ADR-0002) and redundant with AWS native credit alerts.
- **Action-enabled budget** (auto-stop resources) — rejected: requires an IAM
  execution role, costs beyond the first two, and is over-engineering for a
  portfolio MVP.
