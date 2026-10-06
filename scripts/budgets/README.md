# scripts/budgets

Verification tooling for `modules/budgets`. Nothing here is deployed and
nothing changes infrastructure: the filter only reads a saved plan.

| File | Purpose |
|---|---|
| `budget-check.jq` | Answers "did any value of the budget change?" from `tfplan.json`, printing booleans and counts only — never an email address (standard #11). |

Used in `RUNTIME-alerting.md` steps 0 and 1.

## Usage

```bash
terraform show -json tfplan > tfplan.json
jq -f scripts/budgets/budget-check.jq tfplan.json
rm -f tfplan.json          # it holds every value in clear text, including addresses
```

## What it answers

When the root switched `ops_emails` (a plain list) to
`values(var.ops_recipients)` (a **sensitive** map), `module.budgets` started
planning as `update in-place` even though nobody touched the budgets module.
The addresses are the same; what changed is that they now carry Terraform's
sensitive mark, and Terraform treats a change of sensitivity as a change.

So "is `module.budgets` a no-op?" is the wrong question. The right one is
**"did any value change?"**, and that is what this filter answers:

```json
{ "actions": ["update"], "notifications_before": 3, "notifications_after": 3,
  "notification_values_equal": true, "other_attributes_equal": true,
  "sensitive_before": false, "sensitive_after": true }
```

| Field | Gates the apply? | Meaning |
|---|---|---|
| `notification_values_equal` | **yes** | Thresholds and recipient sets are identical, compared as sorted sets so ordering cannot cause a false alarm |
| `other_attributes_equal` | **yes** | Everything outside `notification` (limit, name, cost types) is untouched |
| `notifications_before` / `_after` | **yes** | Both must be 3. Catches an empty list passing the equality test |
| `sensitive_before` / `_after` | no | Explains *why* Terraform shows an update. Expected `false` → `true`, once |

**Stop the apply** if either `*_equal` field is `false` or the two counts
differ: the update would change who receives budget alerts, or the budget
itself.

## Why the sensitivity check looks convoluted

Per [Terraform's JSON plan format](https://developer.hashicorp.com/terraform/internals/json-format),
`before_sensitive` and `after_sensitive` mirror the structure of `before` and
`after` "with all sensitive leaf values replaced with true, and all
non-sensitive leaf values omitted". They contain no data — only `true` markers
and empty containers.

A first version of this filter asked "is this field truthy?" and got the answer
backwards in both directions:

- `before_sensitive.notification` is `[{"subscriber_email_addresses": []}, …]`
  — nothing sensitive, but **jq treats an empty array as truthy**, so it
  reported `true`.
- `after_sensitive.notification` is a bare `true`, because one sensitive
  element makes the whole set sensitive — and iterating *into* a `true` yields
  nothing, so it reported `false`.

Hence `has_sensitive_leaf`: recurse and look for a literal `true` anywhere
below. Do not "simplify" it back.
