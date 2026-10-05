# modules/alerting

Notification layer of PyroSense: two KMS-encrypted SNS **standard** topics with
email subscriptions.

| Topic | Name | Publisher | How the publisher is authorized | Audience |
|---|---|---|---|---|
| Fire-risk alerts | `<name_prefix>-fire-alerts` | ingest Lambda (`alerts.publish_alert`) | Its own IAM role (identity policy) | Responders (`fire_alert_recipients`) |
| Operational alarms | `<name_prefix>-ops-alarms` | CloudWatch Alarms (future `observability`) | A topic policy statement for the `cloudwatch.amazonaws.com` service principal | Platform operators (`ops_recipients`) |

Design decisions: [ADR-0014](../../docs/adr/ADR-0014-alerting-module-shape.md)
(one module with two purpose-built topics; recipient labels as `for_each`
keys) and [ADR-0015](../../docs/adr/ADR-0015-email-only-alert-channel-v1.md)
(email-only delivery in v1.0, scoped as non-life-safety).

> [!IMPORTANT]
> **Pending confirmations after `apply` are expected and are not a failed
> apply.** SNS emails every new address a confirmation link. Terraform cannot
> confirm email subscriptions, and until an address is confirmed SNS delivers
> nothing to it. Unconfirmed subscriptions are deleted by SNS after 48 hours.
> Every demo cycle creates new subscriptions, so every cycle needs a new
> confirmation.

## Resources

| Address | Purpose |
|---|---|
| `aws_sns_topic.fire_alerts` / `.ops` | The topics. `fifo_topic = false` and `kms_master_key_id` are both set explicitly |
| `data.aws_iam_policy_document.tls_only["fire_alerts"]` / `["ops"]` | One TLS-deny document per topic. `for_each` because each statement must name its own topic ARN in `resources`; a Deny scoped to the wrong ARN protects nothing |
| `data.aws_iam_policy_document.ops` | Merges the ops TLS document via `source_policy_documents` and adds `AllowCloudWatchAlarms` |
| `aws_sns_topic_policy.fire_alerts` / `.ops` | Attaches each document to its topic |
| `aws_sns_topic_subscription.fire_alerts["<label>"]` / `.ops["<label>"]` | One `email` subscription per recipient |
| `data.aws_caller_identity` / `aws_region` / `aws_partition` | Account, region and partition for the hand-built alarm ARN in the CloudWatch condition. Nothing is hardcoded |

`source_policy_documents` merges documents and requires unique SIDs across
them. Ours are `DenyInsecureTransport` (from the TLS document) and
`AllowCloudWatchAlarms` (defined inline), so both survive into one JSON with
two statements. Writing the TLS rule once means the two topics cannot drift.

**The topic policies grant nothing positive except the CloudWatch statement.**
They are a Deny, not an allow-list. The ingest Lambda publishes because its own
IAM role allows it, not because of anything here. Positive access lives in
roles; resource policies only set barriers — the same pattern as the queue
policies in `modules/messaging`.

The Deny is scoped to `sns:Publish`, matching AWS's documented example. It is
**not** extended to other SNS actions: that extension is unverified, and an
over-broad Deny on a resource policy is how you lock yourself out of your own
topic.

## Why standard, and not FIFO

Three independent reasons, any one of which is decisive:

1. **A FIFO topic cannot deliver to email at all.** AWS: *"SNS FIFO topics
   can't deliver messages to customer managed endpoints, such as email
   addresses, mobile apps, phone numbers for text messaging (SMS), or HTTP(S)
   endpoints… Attempts to subscribe customer managed endpoints to SNS FIFO
   topics result in errors."* FIFO delivers only to SQS queues.
2. **The approved Python would fail on every publish.** FIFO requires a
   `MessageGroupId` on every message; `alerts.publish_alert` sends `TopicArn`,
   `Subject` and `Message` and nothing else.
3. **Neither FIFO guarantee buys anything here.** Ordering: alerts from
   different devices have no causal relation, the suppression window
   (ADR-0005) means at most one alert per device per window, and each message
   is self-contained. Deduplication: already solved upstream and more
   precisely — the DynamoDB suppression slot dedups *per device over the
   suppression window*, whereas FIFO dedups identical content, and two CRITICAL
   readings seconds apart differ in `seq`, `ts_device` and `smoke_ppm`.

Consistency argument: the ingest queue upstream is standard too. Imposing
strict ordering here would order a stream that already lost its order
upstream. ADR-0008 solves the problem in the right layer — idempotency at the
consumer.

## Why the ops topic needs an explicit Allow

`aws_sns_topic_policy` sets the topic's `Policy` attribute, which is a single
attribute, not a list — attaching ours replaces the default policy a topic is
born with.

- **The Lambda is unaffected.** It is an IAM role in the same account; its
  `sns:Publish` comes from its own identity policy. Within one account, an
  Allow in either the identity policy or the resource policy is enough.
- **CloudWatch is not.** A service principal has no IAM identity and no
  identity policy. The topic policy is the only surface where it can be
  authorized. Without that statement, every alarm changes state and publishes
  nothing, and the failure appears only in the alarm's history — in no log.

The two conditions on that statement prevent the **confused deputy** problem.
`cloudwatch.amazonaws.com` is the CloudWatch service globally, not *your*
CloudWatch: without conditions, an alarm in someone else's account could name
this topic as its action and CloudWatch would faithfully publish into it.

| Condition | What it pins down |
|---|---|
| `StringEquals aws:SourceAccount` | The alarm belongs to this account |
| `ArnLike aws:SourceArn` = `arn:<partition>:cloudwatch:<region>:<account>:alarm:*` | And it is an alarm, in this region, in this account |

`alarm:*` rather than exact names: the alarms do not exist yet and will be
created by `observability`. Pinning names would couple this module to that
naming and would silently deny any alarm named outside the convention.

Note the deliberate asymmetry with `modules/security`: the **key** policy uses
`StringEqualsIfExists` because it is unverified whether CloudWatch populates
`aws:SourceAccount` on its KMS calls, and a missing key there would block
delivery. Here `StringEquals` is strict, because a missing key must deny —
otherwise any account's alarms could publish. If CloudWatch does not populate
it, this statement fails loudly in the runtime test instead of quietly opening
the topic.

## What the CMK protects, and what it does not

Worth stating precisely, because "we encrypted the topic" is a claim a reviewer
will probe.

**There is real data at rest.** SNS stores the message between the `Publish`
call and delivery to every subscriber: *"SSE encrypts messages as soon as
Amazon SNS receives them. The messages are stored in encrypted form, and only
decrypted when they are sent."* For email that window can reach **6 hours** —
the SMTP retry policy is 50 attempts over 6 hours before the message is
discarded. If a recipient's mail server is down, a message carrying device
coordinates sits in SNS storage for that long. That is what the CMK protects.

**SSE covers the message body only.** AWS: *"SSE doesn't encrypt: Topic
metadata (topic name and attributes), Message metadata (subject, message ID,
timestamp, and attributes), Data protection policy, Per-topic metrics."*

The `Subject` built by `alerts.py` is
`[PyroSense CRITICAL] fire risk at PYRO-T1-0042`, so the `device_id` is stored
unencrypted while the coordinates, which are in the body, are not. That is
consistent with ADR-0009, which whitelists `device_id` for structured logs and
excludes coordinates. The classification is the same on both surfaces.

**Protection ends at delivery.** Once the email is delivered, the whole
message — coordinates included — sits in a mailbox in plaintext indefinitely.
The CMK buys two concrete things: confidentiality for the in-AWS window above,
and an audit trail, since every decrypt is a CloudTrail event. It does not buy
end-to-end confidentiality, and the README of a serious project should not
imply that it does.

## Inputs

| Variable | Type | Sensitive | Validation | Root source |
|---|---|---|---|---|
| `name_prefix` | string | no | `^[a-z0-9-]{1,64}$` | `local.name_prefix` |
| `kms_key_arn` | string | no | KMS **key** ARN regex (no alias, no bare key id) | `module.security.kms_key_arn` |
| `fire_alert_recipients` | map(string) `{label = email}` | **yes** | ≥ 1 entry; labels `^[a-z0-9-]{1,64}$`; values match the budgets email regex; no duplicate address (case-insensitive) | `var.fire_alert_recipients` |
| `ops_recipients` | map(string) `{label = email}` | **yes** | the same four rules | `var.ops_recipients` |

**Why maps keyed by label, not lists of addresses.** Terraform always discloses
`for_each` keys in resource addresses, and rejects sensitive values in
`for_each` outright. A list turned into a set would make each address a key, so
it would print in every plan and CI log and live in state addresses. Labels
keep addresses out of the resource graph and keep the keys stable: removing one
recipient destroys exactly that subscription, where a list indexed by position
would shift every later index and recreate those subscriptions — new
confirmation emails and a delivery gap until someone clicks.

The label-format validation is what makes the scheme hold: without it, someone
could write `{ "sebas@example.org" = "sebas@example.org" }` and put the address
back into the resource address. It fails at plan instead.

The duplicate-address validation is not about keys (a map cannot repeat a key).
It rejects two labels pointing at the same address, because SNS identifies a
subscription by topic + protocol + endpoint: that would be two Terraform
resources governing one SNS subscription, and destroying either would
unsubscribe the address while the other still believes it exists. The
comparison ignores case because `A@x.org` and `a@x.org` are distinct strings to
Terraform, and whether SNS treats them as one endpoint is unverified.

**What `sensitive = true` does not protect.** State holds the addresses in
clear text (state bucket: SSE-S3, TLS-only, ADR-0001). `terraform show -json`
prints sensitive values in plain text, and a saved `tfplan` file contains them.
Never commit `tfplan` / `tfplan.json`.

`nonsensitive()` in the subscriptions is also a tripwire: it errors when its
argument is not sensitive, so if someone later drops `sensitive = true` from a
recipients variable, `terraform validate` fails loudly instead of quietly
starting to print addresses.

## Outputs

| Output | Consumer |
|---|---|
| `fire_alerts_topic_arn` | `ingest`: the `ALERT_TOPIC_ARN` env var and the `sns:Publish` grant |
| `fire_alerts_topic_name` | `observability`: the `TopicName` metric dimension |
| `ops_topic_arn` | `observability`: `alarm_actions` / `ok_actions` |
| `ops_topic_name` | `observability`: the `TopicName` metric dimension |

No output contains an email address. Subscriptions are not exported.

## IAM contract for `ingest` (this module grants nothing)

| Service | Action | Resource | Source |
|---|---|---|---|
| SNS | `sns:Publish` | `fire_alerts_topic_arn` | `alerts.py` makes a single `publish` call |
| KMS | `kms:GenerateDataKey*`, `kms:Decrypt` | `kms_key_arn` | AWS SNS docs: publisher permissions for an SSE topic |

The key policy needs no change: SNS-on-publish calls KMS with the *caller's*
credentials, which `EnableIAMDelegation` in `modules/security` already covers.
A `kms:ViaService = sns.<region>.amazonaws.com` condition is a plausible
hardening, but it is **not verified** that SNS's KMS calls carry that context,
so do not add it until the ingest runtime test proves it.

## Contract for `observability`

```hcl
alarm_actions = [module.alerting.ops_topic_arn]
ok_actions    = [module.alerting.ops_topic_arn]
```

Alarms must be in the **same account and region** as the topic — the
`aws:SourceArn` condition admits only `alarm:*` ARNs from this account and
region. Because the topic is CMK-encrypted, CloudWatch also needs the
`AllowCloudWatchAlarms` statement of the **key** policy (`kms:Decrypt`,
`kms:GenerateDataKey*`), which already exists in `modules/security`.

## Cost (us-east-1)

| Item | Price | Demo |
|---|---|---|
| Publish requests | first 1M/month free, then $0.50/M (each 64 KB chunk counts as one request) | $0 |
| Email deliveries | first 1,000/month free, then $2.00 per 100,000 | $0 |
| KMS requests | SNS reuses a data key for up to 5 minutes: `R = B/D × 2P` → ~17,856/month for one always-on publisher | Shares the 20k/month free tier with SQS, S3 and DynamoDB; worst case, cents |

Production projection (ADR-0002): email costs 33× more per delivery than HTTP
($2.00 vs $0.06 per 100k). At any realistic alert volume the binding
constraint is still the per-subscription throttle, not money — see ADR-0015.

## Verification

### Static (run from the root)

`terraform fmt -recursive`, `init -backend-config=config/backend.hcl`,
`validate`, `tflint --recursive`, `trivy config . --tf-vars demo.tfvars`.
Read Trivy's log for parse errors: a green summary over an unparsed file is a
false green this project has already been bitten by.

### Plan (jq)

```bash
terraform show -json tfplan > tfplan.json   # contains addresses in clear text: never commit it

# 1. Exact managed addresses — labels, never addresses
jq -r '[.resource_changes[] | select(.module_address=="module.alerting" and .mode=="managed") | .address] | sort[]' tfplan.json

# 2. Topics: CMK (or after_unknown when security is created in the same plan) and not FIFO
jq '.resource_changes[] | select(.module_address=="module.alerting" and .type=="aws_sns_topic") | {address, name: .change.after.name, fifo: .change.after.fifo_topic, kms: .change.after.kms_master_key_id, kms_unknown: .change.after_unknown.kms_master_key_id}' tfplan.json

# 3. Subscriptions: email protocol, endpoint marked sensitive
jq '.resource_changes[] | select(.module_address=="module.alerting" and .type=="aws_sns_topic_subscription") | {address, protocol: .change.after.protocol, endpoint_sensitive: .change.after_sensitive.endpoint}' tfplan.json

# 4. No address in any resource address or root output
jq -r '[.resource_changes[].address] + [(.planned_values.outputs // {}) | to_entries[] | "\(.key)=\(.value.value)"] | .[]' tfplan.json | grep '@' && echo "FAIL: email found" || echo "OK"

# 5. module.budgets: an in-place update is expected (the addresses gain the
#    sensitive mark), but the VALUES must be identical. Prints booleans only.
jq -f scripts/budget-check.jq tfplan.json
#    expected: notification_values_equal = true, other_attributes_equal = true,
#              sensitive_before = false, sensitive_after = true
```

The topic policies reference topic ARNs that do not exist yet, so their JSON is
unknown at plan time. Inspect them after apply.

### Runtime (AWS CLI, after apply)

Every SNS command here takes `--topic-arn` or `--subscription-arn` — an ARN,
never a name. Get the ARNs with `terraform output`.

```bash
FIRE=$(terraform output -raw alerts_topic_arn)
OPS=$(terraform output -raw ops_topic_arn)

# Encryption, standard topic, subscription counters
aws sns get-topic-attributes --topic-arn "$FIRE" \
  --query 'Attributes.{kms:KmsMasterKeyId,pending:SubscriptionsPending,confirmed:SubscriptionsConfirmed,fifo:FifoTopic}'

# Effective topic policy, as deployed
aws sns get-topic-attributes --topic-arn "$OPS" --query 'Attributes.Policy' --output text | jq .

# Confirm WITH authentication on unsubscribe — do not click the link in the email.
# Copy the Token query parameter out of the confirmation URL, then:
aws sns confirm-subscription --topic-arn "$FIRE" --token '<token>' --authenticate-on-unsubscribe true

# Check it took effect
aws sns list-subscriptions-by-topic --topic-arn "$FIRE" --query 'Subscriptions[].SubscriptionArn' --output text
aws sns get-subscription-attributes --subscription-arn '<arn>' \
  --query 'Attributes.{pending:PendingConfirmation,authenticated:ConfirmationWasAuthenticated}'
```

## Known risks, and what is **not** verified

- **Unsubscribe from the email footer — the intended control did NOT hold.**
  Every delivered alert carries an unsubscribe link, and `sns:Unsubscribe` is
  not one of the actions a topic policy can deny, so there is no preventive
  control available at the resource level. Confirming with
  `--authenticate-on-unsubscribe true` (what `scripts/sns-confirm.sh` does) is
  supposed to make the link fail. **On 2026-10-01 it did not**: a subscription
  confirmed that way was removed from the footer link and
  `SubscriptionsConfirmed` dropped to `0`. The AWS mechanism is real and
  documented, so the gap is in how it applied here, and it is undiagnosed —
  see ADR-0015 for the mitigations and `scripts/README.md` for why the flag
  cannot be verified from the API. **Treat any email recipient as removable by
  anyone holding a delivered message.** Detection: a later `terraform plan`
  reports the removed subscription as one to create.
- **Email throttle: 10 messages/s per subscription, a hard limit.** Exceeding
  it suspends the subscription into `PendingConfirmation` for 30 days. This is
  the main open risk of v1.0 — see ADR-0015 for the failure scenario.
- **Email has no delivery status logging.** Those logs exist for Firehose, SQS,
  Lambda, HTTPS and platform endpoints, not for email. There is no CloudWatch
  signal that an alert was delivered.
- Whether email subscriptions support a **subscription DLQ** is not stated
  explicitly in the SNS docs [?]. As a result `AllowSNSDelivery` in the key
  policy has no user in v1.0.
- **Not verified:** that CloudWatch populates `aws:SourceAccount` and
  `aws:SourceArn` when publishing. Proving it needs an alarm, which belongs to
  `observability`.
- **Not verified:** that the ingest role, holding exactly `kms:GenerateDataKey*`
  and `kms:Decrypt`, can publish. An `aws sns publish` run with admin
  credentials goes through IAM delegation with far broader rights and proves
  nothing about the role. That proof belongs to the ingest runtime test.
