# ADR-0014: Alerting as one module with two purpose-built topics, keyed by recipient labels

- **Status:** Proposed
- **Date:** 2026-09-23
- **Scope:** `modules/alerting`, root `variables.tf` (`ops_emails` → `ops_recipients`, new `fire_alert_recipients`)
- **Related:** ADR-0002 (design for production), ADR-0005 (alert suppression), ADR-0010 (single CMK), ADR-0015 (email-only channel)

## Context

The pipeline needs two SNS topics:

| | Fire-risk alerts | Operational alarms |
|---|---|---|
| Publisher | ingest Lambda, through its **IAM role** | CloudWatch Alarms, as the **service principal** `cloudwatch.amazonaws.com` |
| Payload | JSON with device coordinates (sensitive) | Standard CloudWatch alarm payload |
| Audience | Responders | Platform operators |

The AI-generated draft was a generic "encrypted topic + email subscriptions"
module instantiated twice, with a boolean `allow_cloudwatch_alarms` that turns
on the CloudWatch statement. It also took subscriber emails as a
`list(string)` with `for_each = toset(var.emails)`.

Two facts constrain the design:

1. `aws_sns_topic_policy` replaces the whole topic policy. A service principal
   has no identity policy, so the ops topic needs an explicit Allow. The
   Lambda's same-account identity policy needs nothing on the topic.
2. Terraform always discloses `for_each` keys in resource addresses and
   rejects sensitive values in `for_each`.

## Decision

1. **One module, `modules/alerting`, with two explicit topics** (`fire_alerts`,
   `ops`). The TLS-only Deny statement is written once (a `for_each` data
   source). The CloudWatch Allow exists only in the ops topic's policy
   document. The module has no flags.
2. **Recipients are `map(string)` of `{ label = email }`, marked `sensitive`.**
   Subscriptions iterate over `nonsensitive(toset(keys(...)))`: resource
   addresses carry labels, never addresses.
3. **Two root inputs, because the audiences differ:** `fire_alert_recipients`
   (responders) and `ops_recipients` (operators). `ops_recipients` replaces
   `ops_emails`. The budgets module keeps its `list(string)` input and receives
   `values(var.ops_recipients)`: one intent ("who operates the platform"), one
   input.

## Rationale

- The two topics differ in *who publishes* and *who reads*. In a generic
  module that difference becomes a boolean. The boolean is fixed per instance,
  and the instances are fixed, which is the case project criterion #6 says to
  remove. Written out, each topic's policy can be read in one place, which is
  where a reviewer looks.
- A data-driven alternative ("list of allowed service principals") fails
  because the conditions depend on the service: CloudWatch needs
  `aws:SourceArn` shaped like `…:alarm:*`, and another service would need its
  own shape. Generalizing that means passing condition structures through
  variables, which is more abstraction than two fixed topics justify.
- Labels as keys remove email addresses from plans, CI logs and state
  addresses. They also make keys stable: removing one recipient destroys
  exactly one subscription. With `count`, removing an entry in the middle
  shifts every later index and recreates those subscriptions, which sends new
  confirmation emails and drops delivery until each is confirmed again.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Generic topic module instantiated twice, with `allow_cloudwatch_alarms` bool (the draft) | Flag with one value per fixed instance (criterion #6). Hides each topic's policy behind a conditional |
| Generic module with `publisher_service_principals` list | Conditions differ per service; generalizing them is over-abstraction for two topics |
| Two separate modules | Duplicates versions/variables/README for ~15 lines of difference. One dependency edge from `security` either way |
| `list(string)` + `toset()` keys | Email in every resource address. `toset` treats case variants (`A@x`, `a@x`) as two keys; whether SNS then sees one endpoint or two is unverified, so the variables reject case-insensitive duplicates |
| `list(string)` + `count` | Removing a middle entry shifts indices and recreates subscriptions (new confirmations, silent gap) |
| Pass emails with `-var` / `TF_VAR_*` instead of gitignored tfvars | Does not remove them from state or from `for_each` keys. Moves the secret from a gitignored file to shell history or CI env. No gain over standard #11 |
| Keep `ops_emails` and add `ops_recipients` | Two inputs for one intent can disagree |

## Consequences

- Root contract change: `ops_emails` (list) → `ops_recipients` (map, sensitive).
  `demo.tfvars` / `prod.tfvars` and their `.example` files must be updated.
  `module.budgets` must plan with **no changes**: `values()` returns the
  addresses ordered by label, and `subscriber_email_addresses` is a set in the
  provider schema, so ordering cannot produce a diff as long as the set of
  addresses is unchanged. If its plan shows a diff, stop.
- The addresses reach `module.budgets` carrying Terraform's sensitive mark, so
  its subscriber list renders as `(sensitive value)` in plans from now on. That
  is a display change, not a diff, and the budgets module itself is untouched.
- Plans show `(sensitive value)` for endpoints. State and `terraform show -json`
  still hold addresses in clear text.
- Adding a third topic with the same policy shape means editing this module.
  That is accepted until it happens (see triggers).
- `nonsensitive()` errors if its argument is not sensitive. If a future change
  drops `sensitive = true`, `validate` fails loudly instead of silently
  exposing anything.

## Revisit triggers

- A third topic appears whose policy has the same shape as an existing one →
  reconsider a reusable submodule.
- A non-email protocol is added to a topic (SMS, HTTPS, SQS) → re-evaluate
  whether a subscription DLQ (and `AllowSNSDelivery`) becomes mandatory.
- Terraform gains ephemeral/write-only support for SNS subscription endpoints
  → reconsider keeping addresses out of state.

## References

- Terraform `for_each` (sensitive values not allowed; keys disclosed): https://developer.hashicorp.com/terraform/language/meta-arguments/for_each
- Terraform `nonsensitive` (errors on non-sensitive input): https://developer.hashicorp.com/terraform/language/functions/nonsensitive
- Terraform `show -json` prints sensitive values in plain text: https://developer.hashicorp.com/terraform/cli/commands/show
- Provider `aws_sns_topic_subscription`: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/sns_topic_subscription.html.markdown
- Provider `aws_sns_topic_policy` (default policy shape in the example): https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/sns_topic_policy.html.markdown
- CloudWatch alarm → SNS topic policy (principal, `aws:SourceArn`, `aws:SourceAccount`): https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Notify_Users_Alarm_Changes.html
- `subscriber_email_addresses` is a `schema.TypeSet` (provider source, not the website docs): https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/internal/service/budgets/budget.go
