# scripts/

Helpers for verifying a deployment. Neither script changes infrastructure:
`budget-check.jq` only reads a saved plan, and `sns-confirm.sh` only confirms
a subscription you were already going to confirm by hand.

Both are designed so that **no email address ever reaches stdout, a log, or
the shell history**. That is a project standard (#11), not a nicety: the
addresses in this project are PII and the repository is a portfolio artifact.

| Script | Reads | Prints | Used in |
|---|---|---|---|
| `budget-check.jq` | `tfplan.json` | Booleans and counts only | `RUNTIME-alerting.md` steps 0 and 1 |
| `sns-confirm.sh` | A confirmation link on stdin | One subscription ARN | `RUNTIME-alerting.md` step 6 |

---

## `budget-check.jq`

```bash
terraform show -json tfplan > tfplan.json
jq -f scripts/budget-check.jq tfplan.json
rm -f tfplan.json          # it holds every value in clear text, including addresses
```

### What it answers

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

### Why the sensitivity check looks convoluted

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

---

## `sns-confirm.sh`

```bash
scripts/sns-confirm.sh      # paste the copied link when prompted, press Enter
```

Run it once per confirmation email. Needs the executable bit
(`chmod +x scripts/sns-confirm.sh`) and your normal credentials — **never
`sudo`**, which would make the inner `aws` look for root's credentials instead
of yours.

### What it does and why

It calls `ConfirmSubscription` with `--authenticate-on-unsubscribe true`
instead of letting you click the link. Clicking confirms *without* that flag.

Three deliberate details:

1. **The link is read from stdin, not passed as an argument.** It carries both
   the one-time token and your address; as an argument it would land in
   `~/.zsh_history`.
2. **It uses `unquote`, not `parse_qs`.** `parse_qs` applies form decoding,
   which turns a literal `+` in the token into a space and corrupts it.
   Tokens routinely contain `+`.
3. **It prints only `SubscriptionArn`.** Never the endpoint.

It exits non-zero with a `KeyError` if the link has no `Token` — that means
you pasted something other than the confirmation link.

### Known limitation: the flag could not be verified

> [!WARNING]
> On 2026-10-01 a subscription confirmed through this script was still
> successfully unsubscribed from the footer link of a delivered email, and
> `SubscriptionsConfirmed` dropped to `0`. Treat an email subscription as
> **removable by anyone holding a delivered message** until that is diagnosed.
> See ADR-0015 and the module README.

Two facts make this hard to verify in advance:

- `GetSubscriptionAttributes` returns no attribute exposing
  `AuthenticateOnUnsubscribe`. The only related attribute,
  `ConfirmationWasAuthenticated`, reports that the *confirmation request* was
  signed — which is true whenever you use the CLI, whether or not the flag took
  effect. **It is not proof that unsubscribe is protected.**
- The only real test is attempting the unsubscribe, and if the protection is
  absent the test leaves you unsubscribed.

Running the script is still correct: AWS's own CodeGuru detector flags *not*
setting the flag as a finding, and it costs nothing. Just do not treat it as a
guarantee.
