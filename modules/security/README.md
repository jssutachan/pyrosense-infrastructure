# modules/security

Creates the single customer-managed KMS key (CMK) that encrypts every PyroSense
component storing data at rest, and the key policy that authorizes its consumers.

**Decision record:** [ADR-0010](../../docs/adr/ADR-0010-single-pipeline-cmk.md)

This is the **first module in the build order**. `messaging`, `storage`,
`alerting`, `iot`, `ingest` and `observability` all consume `kms_key_arn`.

## What it creates

| Resource | Purpose |
|---|---|
| `aws_kms_key.pipeline` | Symmetric, single-region CMK with annual rotation |
| `aws_kms_alias.pipeline` | `alias/<name_prefix>-pipeline` — a stable, human-readable handle |

The module creates **two resources and one policy**. The policy is where the
value is; the rest is scaffolding.

## Why a customer-managed key

Not for stronger cryptography — AWS-managed keys use the same algorithms. **The
CMK is required because its policy is editable, and three of our consumers can
only be authorized there.**

An AWS-managed key such as `alias/aws/sns` cannot be given a policy statement.
Consequently:

- A **CloudWatch alarm cannot publish** to an SNS topic encrypted with
  `alias/aws/sns`, because that key's policy grants CloudWatch neither
  `kms:Decrypt` nor `kms:GenerateDataKey`.
- An **SNS subscription cannot deliver** to an encrypted SQS dead-letter queue
  without a key granting the SNS service principal.

Both paths are how this platform reports its own failures. A silently broken
alarm on the ingest DLQ is worse than no alarm, because it grants false
confidence.

## The key policy: four statements, two categories

Services reach KMS in one of two ways, and the distinction determines where a
permission must live.

### Category 1 — services calling with the caller's credentials

When the ingest Lambda writes to S3, **S3 calls KMS on the Lambda's behalf**,
using the Lambda's role. One statement covers all such cases:

| Sid | Principal | Covers |
|---|---|---|
| `EnableIAMDelegation` | this account (`:root`) | SQS, S3, DynamoDB, SNS-on-publish |

The statement does not grant usage — it **delegates the decision to IAM**. A KMS
key denies every principal by default, including the account root, and IAM
policies have no effect until the key policy enables them. Without this
statement, a perfectly correct IAM policy on the Lambda role does nothing.

**Consequence for consuming modules:** the role writing to any encrypted resource
needs `kms:GenerateDataKey` and `kms:Decrypt` on this key ARN in its *own IAM
policy*, even though its application code never mentions KMS.

### Category 2 — services calling as themselves

These have **no IAM role to attach a policy to**, so this key policy is the only
place they can be authorized.

| Sid | Principal | When it is used | Constraint |
|---|---|---|---|
| `AllowCloudWatchLogs` | `logs.<region>.amazonaws.com` | Encrypting log groups | `ArnLike` on the log-group ARN in the encryption context |
| `AllowCloudWatchAlarms` | `cloudwatch.amazonaws.com` | Alarm publishing to encrypted SNS | `StringEqualsIfExists` on `aws:SourceAccount` |
| `AllowSNSDelivery` | `sns.amazonaws.com` | SNS delivering to an encrypted SQS DLQ | `StringEqualsIfExists` on `aws:SourceAccount` |

Three details that are load-bearing and easy to get wrong:

1. **The Logs principal is region-qualified** (`logs.us-east-1.amazonaws.com`,
   not `logs.amazonaws.com`). Copying this module to another region without
   updating it stops log encryption; the symptom is an empty log group. The
   Alarms and SNS principals are *not* region-qualified. There is no general
   rule — each service's documentation is the authority.
2. **The trailing `*` in `kms:GenerateDataKey*` is not cosmetic.** AWS has
   documented alarm failures caused by granting only the exact action name,
   because related actions such as `GenerateDataKeyPair` are not covered.
3. **`Resource: "*"` inside a key policy means "this key"**, not "all keys" — the
   policy is already attached to one resource. The same text in an IAM policy
   means the opposite.

### The encryption-context condition

`kms:EncryptionContext:aws:logs:arn` is the log-group ARN, sent by CloudWatch
Logs on every KMS call and evaluated by KMS before authorizing. Conditioning on
it means the grant is unusable for any log group outside this account and region
— least privilege that actually constrains, rather than a permission scoped only
by principal.

## Documented exception to project standard #1

`EnableIAMDelegation` uses `Action: "kms:*"` with `Resource: "*"`, which standard
#1 forbids. This is deliberate and is argued in full in ADR-0010. In short: the
effective scope is one key in one account; AWS documents this as the canonical
default; and enumerating principals explicitly would create a dependency cycle
with `modules/ingest` and raise the risk of an unrecoverable lockout.

**Trigger to revisit:** a second human operator with KMS permissions, or an audit
requirement for separation of duties.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | `string` | — | Resource prefix, e.g. `pyrosense-demo`. Supplied by the root as `local.name_prefix`; never set in tfvars. |
| `deletion_window_days` | `number` | `7` | Waiting period before AWS KMS permanently deletes the key after deletion is scheduled. Must be 7–30. |

## Outputs

| Name | Description |
|---|---|
| `kms_key_arn` | **The value every other module consumes.** |
| `kms_key_id` | Key ID, for resources that take an ID rather than an ARN. |
| `kms_alias_name` | `alias/<name_prefix>-pipeline`, for CLI verification. |
| `kms_alias_arn` | Alias ARN, for resources that accept one. |

## Cost

| Item | Cost |
|---|---|
| Key storage | $1.00/month, prorated hourly |
| First and second rotation | One prorated month each |
| Symmetric requests | First 20,000/month free across all regions |
| Key pending deletion | **No charge** |

Under the ADR-0002 teardown cycle, a validation run of a few hours costs cents.
A key left alive for a full month consumes half the $2 demo budget of ADR-0003 —
which is the budget working as designed, not a misconfiguration.

## Deletion is irreversible

`terraform destroy` **schedules** deletion; it does not delete immediately. After
the waiting period elapses, every object in S3, every item in DynamoDB and every
queued message encrypted under this key becomes **permanently unreadable**.
Cancelling the scheduled deletion during the window restores the key, and
billing resumes as though it had never been scheduled.

The root variable `kms_deletion_window_days` defaults to `30`, not `7`: if
someone runs `apply` without a `-var-file`, the failure mode should be "the key
takes longer to disappear", never the destructive one.

## Verification after apply

```bash
# Key exists, symmetric, enabled
aws kms describe-key --key-id alias/pyrosense-demo-pipeline

# Policy stored by KMS matches what the policy document generated — expect 4 statements
aws kms get-key-policy \
  --key-id alias/pyrosense-demo-pipeline \
  --policy-name default --output text | jq '.Statement[].Sid'

# Rotation active
aws kms get-key-rotation-status --key-id alias/pyrosense-demo-pipeline
```

A successful `apply` is itself a verification `plan` cannot perform: KMS runs a
**policy lockout safety check** at key creation and refuses a policy that would
leave the key unmanageable.

## Not yet verified

The key exists and its policy is structurally valid, but **no service has used
it**. Three runtime checks remain open until `modules/observability` exists:

- [ ] A log group encrypted with this key successfully ingests events
- [ ] A CloudWatch alarm successfully publishes to an SNS topic encrypted with this key
- [ ] Whether `aws:SourceAccount` appears in the CloudTrail entry for
      `GenerateDataKey` from `cloudwatch.amazonaws.com` — if it does, tighten
      both conditions to `StringEquals`

Until then, the honest claim for this module is *"code-complete, policy validated
by AWS at key creation"* — not *"verified in operation"*.

## Notes for consuming modules

- **`modules/storage`:** set `bucket_key_enabled = true` on the cold store, or
  per-object KMS calls will exceed the free tier at production volumes.
- **`modules/messaging`:** `sqs_managed_sse_enabled = true` and
  `kms_master_key_id` on the same queue is an **invalid configuration that fails
  at apply time**. Set `kms_master_key_id` and omit the other.
- **`modules/messaging`:** `kms_data_key_reuse_period_seconds` defaults to 300
  and caps KMS call volume. Shorter is more secure and more expensive.
- **`modules/ingest`:** verify whether DynamoDB requires `kms:CreateGrant` in the
  Lambda role's IAM policy before writing it. Symptom of getting it wrong is
  `AccessDenied` at table creation.
