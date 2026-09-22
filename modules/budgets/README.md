# Módulo: budgets

Account-wide AWS Budgets guardrail for the PyroSense account: a single
recurring monthly cost budget that emails when actual or forecasted spend
crosses a threshold.

## What it creates

| Budget | Window | Question it answers |
|---|---|---|
| `<prefix>-monthly-cost` | Monthly, recurring | *Did I leave something running this month?* |

## Why account-wide and not scoped to `Project=PyroSense`

A tag-scoped budget looks tighter, but it is weaker here:

1. Cost-allocation tags must be activated by hand in the billing console.
   That is clickops, and this repository does not do clickops.
2. A tag-scoped budget is blind to untagged resources — exactly the
   mistake a guardrail exists to catch. A budget that ignores your errors
   is a placebo.

## Why credits are excluded by default

`cost_types.include_credit` defaults to `true` in AWS. With promotional
credits applied, real usage nets to `$0`, the budget never crosses a
threshold, and the first signal arrives only when the credits run out and
a real invoice appears.

`include_credits = false` measures **gross consumption** — the number that
answers "how fast am I burning the grant?". Flip it to `true` once the
account pays its own way and the question becomes "what will I be
invoiced?".

`include_refund` is `false` for the same reason: a refund is money
returning for spend that already happened; netting it out understates
consumption and delays the alert.

## Behaviour worth knowing before you rely on this

- **Budget data refreshes every ~8–12 hours.** This is a guardrail, not an
  alarm: a runaway resource can burn a lot inside one refresh window. The
  `FORECASTED` notification shortens that gap, and the operating model
  (*turn on, demonstrate, destroy*) exists because no budget is fast
  enough on its own.
- **Subscribers are not asked to confirm.** Unlike SNS email
  subscriptions, budget notification emails start arriving immediately —
  there is no pending-confirmation state to chase.
- **A notification with no subscribers is rejected by AWS.** The module
  guards against this with an input validation: `notification_emails` must
  contain at least one address, so the failure surfaces at `plan` time
  instead of as an API error mid-apply.

## Cost

`$0`. Monitoring cost budgets and receiving their notifications is free
and unmetered. The "first two free, then `$0.10`/day" tier applies to
*action-enabled* budgets — those that run IAM or EC2 actions
automatically. This module defines no action.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | `string` | — | Resource name prefix, e.g. `pyrosense-demo`. |
| `limit_usd` | `number` | — | Monthly cost limit in USD. |
| `notification_emails` | `list(string)` | — | Recipients. At least one required. |
| `include_credits` | `bool` | `false` | Whether credits offset measured spend. `false` measures gross consumption. |
| `actual_threshold_percents` | `list(number)` | `[80, 100]` | ACTUAL-spend thresholds, as a percentage of `limit_usd`. |
| `forecasted_threshold_percent` | `number` | `100` | FORECASTED-spend threshold, as a percentage of `limit_usd`. |

## Outputs

| Name | Description |
|---|---|
| `budget_name` | Name of the monthly cost budget. |
| `budget_arn` | ARN of the monthly cost budget. |

## Tags

The budget inherits the provider's `default_tags`
(`Project` / `Environment` / `ManagedBy`). `aws_budgets_budget` gained a
`tags` argument in AWS provider `5.50.0`; this module requires `>= 6.0`,
so default tags apply with no per-resource exception needed. See ADR-0004
for how this contract is linted.

## Verify after apply

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# List budgets and their limits
aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount,Unit:TimeUnit}'

# Confirm credits are excluded (CostTypes.IncludeCredit must be false)
aws budgets describe-budget --account-id "$ACCOUNT_ID" \
  --budget-name pyrosense-demo-monthly-cost \
  --query 'Budget.CostTypes'

# Confirm notification thresholds and subscribers
aws budgets describe-notifications-for-budget --account-id "$ACCOUNT_ID" \
  --budget-name pyrosense-demo-monthly-cost
```
