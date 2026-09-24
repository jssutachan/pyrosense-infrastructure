# ADR-0010 — A single customer-managed KMS key for the whole pipeline

**Status:** Accepted · 2026-09-22
**Scope:** `modules/security`, and every module that stores data at rest

## Context

Standard #2 of this project requires encryption at rest on every resource that
supports it. Six components in PyroSense persist data: SQS (and its DLQ),
DynamoDB, S3, SNS, and CloudWatch Logs. Encryption is therefore not one decision
but three: **which key type**, **how many keys**, and **who is allowed to use
them**.

Two constraints make the answer non-obvious.

First, the AWS-managed keys are free but **their policies cannot be edited**.
This is disqualifying, not merely inconvenient: with `alias/aws/sns`, a
CloudWatch alarm cannot publish to the encrypted topic, because that key's
policy grants CloudWatch neither `kms:Decrypt` nor `kms:GenerateDataKey`, and
AWS owns the policy. The same applies to an SNS subscription dead-letter queue,
which requires a key whose policy grants the SNS service principal. The
alarm-and-DLQ path is how this platform reports its own failures, so an
unencrypted alert topic and a silently broken alarm are both unacceptable.

Second, DynamoDB is *always* encrypted; there is no option to disable it. The
real decision for DynamoDB is not whether to encrypt but **who controls the
key** — and therefore whether key usage can be audited, rotated and policy-
controlled at all.

## Decision

Create **one customer-managed KMS key (CMK)** in `modules/security`, shared by
SQS, the SQS DLQ, DynamoDB, S3, SNS and CloudWatch Logs. It is symmetric
(`SYMMETRIC_DEFAULT`), single-region, with annual rotation enabled, and it is
exposed to the other modules through `kms_key_arn`.

Its key policy contains exactly four statements, in two categories:

1. **IAM delegation** (`Principal: <account>:root`, `kms:*`). Authorizes the
   account to decide through IAM. This covers every service that calls KMS with
   the *caller's* credentials: SQS, S3, DynamoDB and SNS-on-publish.
2. **Three service principals**, each of which calls KMS as itself and has no
   IAM role to attach a policy to, making this key policy the only surface where
   they can be authorized:
   - `logs.<region>.amazonaws.com` — encrypts log groups. Constrained by
     `ArnLike` on `kms:EncryptionContext:aws:logs:arn` to this account and
     region.
   - `cloudwatch.amazonaws.com` — lets alarms publish to the encrypted SNS
     operations topic.
   - `sns.amazonaws.com` — lets SNS deliver to an encrypted SQS dead-letter
     queue.

`modules/security` is the first module in the build order, because every module
that stores data consumes its output.

`deletion_window_days` is the only value that differs by environment: 7 in demo
(the AWS floor, for fast teardown), 30 in production (maximum margin to reverse
an accidental deletion). This is the ADR-0002 pattern — one codebase, per-
environment values in tfvars.

**Out of scope:** the Terraform state bucket, which stays on SSE-S3 per
ADR-0001. Encrypting state with this CMK would reintroduce the bootstrap
chicken-and-egg problem and create a catastrophic failure mode.

## Rationale

- **The CMK is not primarily a cryptographic choice; it is an authorization
  surface.** A KMS key denies every principal by default, including the account
  root, unless a key policy allows it — and IAM policies have no effect without
  the key policy first enabling them. Three of our consumers are service
  principals with no IAM identity, so an editable key policy is the only
  mechanism that can authorize them. That requirement alone forces a CMK.
- **One key, not six.** Key storage is $1/month per key regardless of use, and
  six keys means six policies to keep aligned as modules are added. More
  importantly, splitting the key does not reduce the blast radius in a
  single-account, single-pipeline system: every consumer belongs to the same
  trust boundary. Least privilege is enforced per *principal* — through IAM and
  through the encryption-context condition on the Logs statement — not by
  multiplying keys.
- **Cost is negligible and largely unavoidable.** With the CMK already required
  for the alarm path, encrypting the remaining resources with it costs nothing
  extra: the KMS free tier covers 20,000 symmetric requests per month, SQS
  caches its data key for 300 seconds by default, and S3 Bucket Keys collapse
  per-object KMS calls. Under the demo teardown cycle the key is billed prorated
  by the hour, and a key pending deletion incurs no charge at all.
- **Why encryption is justified for telemetry at all**, given that a non-critical
  reading has little intrinsic value: the sensitive asset is not the temperature
  but the **geolocation of the detection infrastructure** — the complete dataset
  is a map of where the reserve is monitored and, more usefully to an arsonist
  or illegal logger, where it is not. The alerting path additionally carries
  contact data for public-institution staff, which standard #11 already treats
  as PII.
- **`enable_key_rotation = true`** costs one prorated month for each of the first
  two rotations and is transparent: the key ID and ARN do not change, and old
  material is retained to decrypt historical ciphertext.

## Alternatives considered

- **AWS-managed keys (`alias/aws/sns`, `alias/aws/sqs`)** → **rejected**: their
  policies cannot be edited, which breaks CloudWatch alarms publishing to an
  encrypted SNS topic and SNS delivering to an encrypted DLQ. Free, but
  functionally disqualified.
- **DynamoDB's default AWS-owned key** → **rejected**: free and always-on, but
  the policy is invisible, usage cannot be audited per key, and rotation is not
  controllable. Choosing it would also split the pipeline across two key
  regimes for no gain.
- **One CMK per domain** (data / messaging / alerting) → **rejected**: $3/month
  and three policies to keep in sync, in exchange for a blast-radius reduction
  that does not exist when all consumers share one trust boundary. **Trigger to
  revisit:** a requirement to revoke access to alerting without interrupting
  ingestion, or a multi-tenant deployment.
- **Enumerating key administrators and key users explicitly**, as
  `terraform-aws-modules/kms` does, instead of the `kms:*` IAM delegation →
  **rejected**: it creates a dependency cycle, since the Lambda execution role
  is created in `modules/ingest`, which consumes this module's key ARN. It also
  raises the lockout risk that AWS explicitly warns about — a key whose last
  authorized principal is deleted is recoverable only through AWS Support. See
  the standard-#1 exception below.
- **Encrypting the Terraform state bucket with this CMK** → **rejected**, per
  ADR-0001.

## Documented exception to project standard #1

Standard #1 forbids `Action: "*"` with `Resource: "*"`. The `EnableIAMDelegation`
statement uses `kms:*` with `Resource: "*"`, and this is deliberate.

Inside a key policy, `Resource: "*"` denotes **this key only** — the policy is
already attached to a single resource — and the principal is this account's own
root ARN, which in a resource policy denotes the account as an entity rather than
the root user. The effective scope is *one key, one account*. AWS documents this
statement as the canonical default and warns that omitting it can render a key
unmanageable.

The accepted cost: the same statement also delegates the power to alter the key
policy and to schedule key deletion to any account identity with sufficient IAM
permissions. With a single human operator this is acceptable.

**Trigger to revisit:** a second human operator with KMS permissions, or an audit
requirement for separation of duties. At that point this statement is replaced by
separate administrator and user statements, and the dependency cycle is broken by
creating IAM roles in a module that precedes `modules/security`.

## Open question, deliberately deferred

The CloudWatch and SNS statements use `StringEqualsIfExists` on
`aws:SourceAccount`, not `StringEquals`. It is **unverified** whether those
services populate that condition key on their KMS calls. With `StringEquals`, a
missing key denies the request and the alarm fails silently — and the DLQ alarm
is the only channel that reports a broken ingestion path. `IfExists` enforces the
value when present without blocking when absent.

The residual security exposure is near zero in a single-account deployment: the
only scenario the condition would block is a CloudWatch or SNS principal from
another account, which cannot occur without an explicit cross-account
configuration.

**Resolution path:** when `modules/observability` is deployed, inspect the
CloudTrail entry for `GenerateDataKey` from `cloudwatch.amazonaws.com`. If
`aws:SourceAccount` is present, tighten to `StringEquals` and supersede this
section.

## Consequences

- **Positive:** encryption at rest satisfied across six components with one key,
  one policy and one rotation schedule. CloudTrail gives a single audit trail for
  all pipeline key usage. Adding a module means adding an IAM permission, not a
  key.
- **Positive:** the encryption-context condition on the Logs statement is real
  least privilege — the grant is unusable outside this account and region.
- **Negative:** the key is a single point of failure. Scheduling its deletion
  renders every object in S3, every item in DynamoDB and every queued message
  permanently unreadable. Mitigated by `deletion_window_days` (30 in production)
  and by Terraform being the only path that can schedule it.
- **Negative:** the standard-#1 exception above must be restated in
  `modules/security/README.md`, or a reviewer will read the policy as careless
  rather than deliberate.
- **Follow-up (infra):** `modules/storage` must set `bucket_key_enabled = true`
  on the cold store, or per-object KMS calls will exceed the free tier at
  production volumes.
- **Follow-up (infra):** verify whether DynamoDB requires `kms:CreateGrant` in
  the consuming role's IAM policy. Some services use grants rather than direct
  key-policy permissions; the symptom of getting this wrong is `AccessDenied` at
  table creation.
- **Related:** the DynamoDB table encrypted by this key holds both the dedup
  items of ADR-0008 and the alert-suppression items of ADR-0005. The log groups
  it encrypts carry the structured logs of ADR-0009.
