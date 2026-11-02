# ADR-0013: Storage — single-table key design and a flat (non-tiered) cold archive

- **Status:** Proposed
- **Date:** 2026-09-22
- **Scope:** `modules/storage`, `src/ingest_lambda/persistence.py`, `cold_store.py`, `alerts.py`
- **Related:** ADR-0002, ADR-0005, ADR-0008, ADR-0010, ADR-0012

## Context

The ingest Lambda persists every valid message twice: a hot copy in
DynamoDB (recent state, dedup guard, alert suppression) and a raw cold copy
in S3 (audit trail, analytics source). The Python that writes both is
approved and tested; the infrastructure must match it exactly.

The AI-generated draft of `modules/storage` got the key schema right but:

1. tiered cold objects to Standard-IA and Glacier on a schedule;
2. exposed PITR, deletion protection and lifecycle days as variables;
3. used `0` as a sentinel for "never expire";
4. cited ADR numbers that point to unrelated decisions.

Facts that drive this decision (AWS documentation, consulted 2026-09-22):

- S3 Lifecycle does not transition objects smaller than 128 KB by default;
  Standard-IA and Glacier Instant Retrieval bill a 128 KB minimum per
  object; Glacier Flexible Retrieval and Deep Archive add 40 KB of metadata
  per archived object; each transition is a billed request.
- `cold_store.py` writes one JSON object of a few hundred bytes per message.
- DynamoDB PITR is billed per GB-month of table size; this table is
  TTL-bounded.
- Both Python item families write `expires_at` as epoch seconds.

## Decision

1. **One DynamoDB table, generic keys `pk`/`sk` (strings)**, two item
   families distinguished by prefix:
   - telemetry: `pk = DEV#<device_id>`, `sk = SEQ#<seq:012d>`;
   - alert slot: `pk = ALERT#<device_id>`, `sk = STATE`.
   TTL on `expires_at`. On-demand billing, STANDARD table class, CMK SSE.
2. **PITR always on** (35-day window), not a demo/prod toggle.
3. **Cold bucket stays in S3 Standard with no transitions and no
   current-version expiration.** A single hygiene rule expires noncurrent
   versions after 30 days, removes orphan delete markers and aborts
   incomplete multipart uploads after 7 days.
4. **Versioning on**, despite deterministic keys.
5. **One input, `allow_data_destruction`**, drives both DynamoDB deletion
   protection and S3 `force_destroy`. At the root it is an explicit variable
   with the production-safe default `false`, set to `true` only in
   `demo.tfvars`, and a cross-variable validation rejects `true` when
   `environment = "prod"`.
6. The object prefix `telemetry/` is exported as the ready-to-use IAM ARN
   `telemetry_objects_arn`.

## Rationale

- **Single table:** both families are written by the same Lambda with the
  same TTL mechanism and the same encryption. Neither needs a secondary
  index. The families never share a partition, so single-table here is not
  about pre-joined item collections; it is about one resource, one IAM
  grant, one TTL config and one set of KMS grants. Splitting would change
  `config.py`, `handler.py` and the tests for no functional gain today.
- **No tiering:** for sub-KB objects every tier below Standard costs *more*
  per object than Standard, and the default 128 KB guard makes the draft's
  transitions a silent no-op anyway. Tiering is correct only after
  compaction.
- **PITR always on:** at KB-to-MB table size the cost rounds to zero; a
  toggle would be a variable that exists only to be forgotten in prod.
- **Versioning:** deterministic keys make *honest* retries harmless; they do
  nothing against a buggy or compromised writer that overwrites with
  different bytes. The raw archive is the source of truth, so that is the
  threat worth covering. Noncurrent expiration bounds the cost.
- **One destruction flag:** deletion protection and `force_destroy` express
  the same intent. Two flags allow the half-protected state (table
  protected, bucket wiped), which has no use.
- **Explicit root variable, not a derived local:** ADR-0002 makes the
  tfvars diff the complete demo/prod delta. Deriving the flag from
  `environment` would hide a delta from that diff. The validation keeps the
  main benefit of deriving (the dangerous combination cannot reach apply),
  and the `false` default follows the same rule as
  `kms_deletion_window_days`: no var file means the conservative outcome.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Two tables (telemetry, alert state) | No access pattern needs it today; forces Python + test changes; doubles grants and PITR config. Kept as revisit trigger |
| Keep IA → Glacier transitions | Silent no-op under the 128 KB guard; net cost increase if forced with a size filter |
| S3 Intelligent-Tiering | Objects < 128 KB are not monitored and stay in the Frequent tier |
| `0` = keep forever (draft) | Magic value; negative input also meant "forever" because the draft had no validation. Removed with the expiration itself |
| Disable versioning (immutability by determinism) | Leaves the audit trail unprotected against overwrite with different bytes |
| S3 Object Lock (WORM) | Strongest control, but compliance mode makes the demo destroy cycle impossible; premature before a retention policy exists |
| Random bucket suffix (`bucket_prefix`) | Loses the deterministic name used in docs and evidence; the squatting risk it mitigates is low while the account id is not published |
| Root local `allow_data_destruction = var.environment == "demo"` (first draft of this ADR) | Removes a delta from the tfvars diff that ADR-0002 declares authoritative; the validation gives the same safety |
| Separate `enable_pitr` / `enable_deletion_protection` variables | Violates "a variable must take more than one value" (PITR) and allows inconsistent protection (deletion flag vs `force_destroy`) |

## Consequences

- The cold archive grows without bound in STANDARD. Acceptable at demo
  volume; in prod it is a known, visible cost line.
- Every redelivery that reaches the S3 step creates a noncurrent version
  (identical bytes) kept 30 days.
- Ingest must scope KMS conditions to the **bucket** ARN (bucket keys) and
  the table name (DynamoDB encryption context).
- Three invariants move to ingest/config: `HOT_RETENTION_DAYS` ≥ DLQ
  retention (14 d); `ALERT_SUPPRESSION_MINUTES` < 1440; `seq` unique per
  device within the hot retention.
- `telemetry/` exists in two places (Python `KEY_TEMPLATE`, Terraform
  local). Drift is tech debt until the prefix is passed to the Lambda as an
  environment variable.

## Revisit triggers

- A read pattern needs a GSI or a key schema for only one item family, or a
  third family appears → re-evaluate two tables.
- Native per-table metrics (e.g. conditional-check failures) are needed to
  tell duplicates from suppressed alerts without EMF → two tables.
- Compaction (Firehose, Glue or a batch job producing ≥ 128 KB objects)
  exists → add transitions with the minimum-duration constraints.
- A stakeholder defines a legal retention period for raw telemetry → add
  current-version expiration or Object Lock.
- Cold storage cost appears in the top 3 of the monthly bill → revisit
  compaction priority.
- The account id becomes public or the project moves to prod → evaluate the
  S3 account-regional bucket namespace.

## References

- aws_dynamodb_table (provider 6.x): https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/dynamodb_table.html.markdown
- aws_s3_bucket_lifecycle_configuration: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/s3_bucket_lifecycle_configuration.html.markdown
- aws_s3_bucket (force_destroy, bucket_namespace): https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/s3_bucket.html.markdown
- aws_s3_bucket_server_side_encryption_configuration: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/s3_bucket_server_side_encryption_configuration.html.markdown
- S3 lifecycle transitions: https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html
- S3 storage classes: https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html
- S3 Bucket Keys: https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html
- SSE-KMS permissions and encryption context: https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html
- DynamoDB encryption usage notes: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/encryption.usagenotes.html
- DynamoDB TTL: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html
- DynamoDB pricing: https://aws.amazon.com/dynamodb/pricing/on-demand/
- Terraform 1.9.0 — validation rules can refer to other variables: https://raw.githubusercontent.com/hashicorp/terraform/v1.9/CHANGELOG.md
