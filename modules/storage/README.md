# modules/storage

Hot/cold persistence for the PyroSense ingest pipeline. Design record:
[ADR-0013](../../docs/adr/ADR-0013-storage-key-design-and-flat-cold-archive.md).

| Store | Resource | Question it answers | Lifetime |
|---|---|---|---|
| Hot | DynamoDB table `<prefix>-hot` | "What is happening right now?" | TTL-bounded (`HOT_RETENTION_DAYS`, set by ingest) |
| Cold | S3 bucket `<prefix>-cold-<account_id>` | "What exactly did every sensor send?" | Indefinite (audit trail, analytics source) |

## Resources (7 managed + 2 data sources)

| Address | Purpose |
|---|---|
| `aws_dynamodb_table.hot` | On-demand, STANDARD class, `pk`/`sk` strings, TTL on `expires_at`, PITR 35 d, SSE with the pipeline CMK, deletion protection = `!allow_data_destruction` |
| `aws_s3_bucket.cold` | Deterministic name with account id suffix; `force_destroy = allow_data_destruction`; precondition on the 63-char name limit |
| `aws_s3_bucket_public_access_block.cold` | All four blocks on |
| `aws_s3_bucket_versioning.cold` | Enabled — protects the audit trail against overwrite by a buggy or compromised writer |
| `aws_s3_bucket_server_side_encryption_configuration.cold` | SSE-KMS with the CMK, bucket key on, SSE-C blocked |
| `aws_s3_bucket_lifecycle_configuration.cold` | One hygiene rule: noncurrent versions 30 d, orphan delete markers, abort multipart 7 d. **No tiering** (see below) |
| `aws_s3_bucket_policy.cold` | Deny-only: `aws:SecureTransport = false` |
| `data.aws_caller_identity.current` | Account id for the bucket name |
| `data.aws_iam_policy_document.cold_tls_only` | Bucket policy document |

## Key design (the deepest decision in the project)

The schema is **dictated by the approved Python**; Terraform only declares it.

| Item family | Writer | `pk` | `sk` | Other attributes | `expires_at` |
|---|---|---|---|---|---|
| Telemetry reading | `persistence.store_telemetry` | `DEV#<device_id>` | `SEQ#<seq, 12-digit zero-padded>` | full reading (Decimal numbers) | `ingested_at + HOT_RETENTION_DAYS` |
| Alert suppression slot | `alerts.try_acquire_alert_slot` | `ALERT#<device_id>` | `STATE` | `suppress_until` (epoch s) | `now + 1 day` |

Why each piece matters:

1. **Conditional put = idempotency.** Telemetry uses
   `attribute_not_exists(pk)`: the first delivery of `device_id + seq` wins,
   replays return `ConditionalCheckFailedException` and are skipped
   (ADR-0008).
2. **Conditional put = race-free suppression.** The alert slot uses
   `attribute_not_exists(pk) OR suppress_until < :now`: exactly one
   concurrent Lambda wins the right to publish (ADR-0005).
3. **Zero-padded `seq`** makes lexicographic order equal numeric order, so
   "latest N readings of a device" is one `Query` on `pk` with
   `ScanIndexForward = false`.
4. **Prefixes keep families disjoint.** `DEV#` and `ALERT#` never share a
   partition, so no query can return a mix by accident.
5. **One TTL attribute for both families.** DynamoDB allows one TTL
   attribute per table; both families already write `expires_at` as a
   Number in epoch seconds, the only format TTL honours.

Invariants the table relies on but **cannot enforce** (owned by ingest):

| Invariant | Why | Where to enforce |
|---|---|---|
| `HOT_RETENTION_DAYS` ≥ DLQ retention (14 d) | A message redriven from the DLQ after its hot item was TTL-deleted is treated as new: re-inserted and possibly re-alerted | `modules/ingest`: derive or `precondition` against `messaging` |
| `ALERT_SUPPRESSION_MINUTES` < 1440 | `alerts.py` hardcodes `expires_at = now + 1 day`; a longer window lets TTL delete the slot before `suppress_until` | `config.py` validation (to confirm — not reviewed) |
| `seq` never repeats per device within the hot retention | A repeated `seq` (e.g. counter reset on reboot) is silently dropped as a duplicate | Payload contract (`contract.py`, not reviewed) |

Expired items stay readable until the TTL process deletes them (typically
within days). Any future reader must filter on `expires_at`.

## Why the cold bucket does not tier

`cold_store.py` writes one JSON object per message (hundreds of bytes).

| Fact (AWS docs) | Consequence here |
|---|---|
| Lifecycle skips objects < 128 KB by default | IA/Glacier transitions would be a silent no-op |
| Standard-IA / Glacier IR bill a 128 KB minimum per object | Forcing the transition multiplies the storage bill of each object |
| Glacier Flexible / Deep Archive add 40 KB metadata per object | Same: overhead ≫ payload |
| Each transition is a billed request | Per-message objects maximise request count |

Tiering becomes worth it only after compaction (many readings → few large
objects, e.g. daily Parquet). Until then objects stay in STANDARD. Revisit
trigger in ADR-0013.

## Inputs

| Name | Type | Default | Validation | Root source |
|---|---|---|---|---|
| `name_prefix` | string | — | `^[a-z0-9-]{1,64}$` (+ bucket-name precondition ≤ 63) | `local.name_prefix` |
| `kms_key_arn` | string | — | key ARN regex (no alias, no key id) | `module.security.kms_key_arn` |
| `allow_data_destruction` | bool | — (intent must be explicit) | — (the root variable of the same name defaults to `false` and rejects `true` for `prod`) | `var.allow_data_destruction` (`true` only in `demo.tfvars`) |

## Outputs

| Output | Consumer |
|---|---|
| `table_name` | ingest (`TABLE_NAME`), observability (`TableName` dimension) |
| `table_arn` | ingest IAM |
| `bucket_id` | ingest (`BUCKET_NAME`), CLI |
| `bucket_arn` | ingest IAM (KMS encryption-context condition) |
| `telemetry_objects_arn` | ingest IAM (`s3:PutObject`), so `telemetry/` is typed once |

## IAM contract for `modules/ingest`

`storage` grants nothing. The ingest role needs exactly:

| Service | Actions | Resource | Conditions | Evidence |
|---|---|---|---|---|
| DynamoDB | `dynamodb:PutItem` | `table_arn` | — | Only `put_item` appears in `persistence.py` and `alerts.py`; `ConditionExpression` needs no extra action |
| S3 | `s3:PutObject` | `telemetry_objects_arn` | — | Only `put_object` in `cold_store.py` |
| KMS (for DynamoDB) | `kms:Decrypt` | `kms_key_arn` | `kms:ViaService = dynamodb.<region>.amazonaws.com`; `kms:EncryptionContext:aws:dynamodb:tableName = table_name` | DynamoDB decrypts the table key with the *caller's* identity |
| KMS (for S3) | `kms:GenerateDataKey` | `kms_key_arn` | `kms:ViaService = s3.<region>.amazonaws.com`; `kms:EncryptionContext:aws:s3:arn = bucket_arn` (bucket, **not** object, because bucket keys are on) | PutObject with SSE-KMS requires `kms:GenerateDataKey` |

Not yet proven (the first runtime test of `ingest` settles them — an
`AccessDenied` names the missing action):

- whether S3 PutObject with a bucket key also needs `kms:Decrypt`;
- whether DynamoDB also needs `kms:DescribeKey` from the caller.

Do **not** use the managed policy `AmazonDynamoDBFullAccess` or any S3
managed policy: all grant `Resource: "*"` scopes that violate standard #1.

## Cost (us-east-1)

| Item | Price source | Demo impact |
|---|---|---|
| DynamoDB on-demand writes | $0.625 per million write request units | Cents at demo volume |
| DynamoDB storage | $0.25 per GB-month (after free tier) | KB-scale table ⇒ ~$0 |
| PITR | $0.20 per GB-month of table size | ~$0 (table is TTL-bounded) |
| KMS for S3 | Bucket key: ~1 `GenerateDataKey` per requester per key lifetime instead of 1 per PutObject | Bounded, not proportional to messages |
| S3 PUT requests and storage | **Not modelled** (tech debt) | — |

## Verification

### Static (from the ROOT)

```bash
terraform fmt -recursive
terraform init -backend-config=config/backend.hcl
terraform validate
tflint --recursive
trivy config . --tf-vars demo.tfvars   # read the LOG for parse errors, then the table
terraform plan -var-file=demo.tfvars -out=tfplan
terraform show -json tfplan > tfplan.json
```

### Plan artifact checks

```bash
# 1. Exact address list — expect 7 managed resources
jq -r '[.resource_changes[] | select(.module_address=="module.storage" and .mode=="managed") | .address] | sort[]' tfplan.json

# 2. Table: keys, TTL, PITR, SSE, protection
jq '.resource_changes[] | select(.module_address=="module.storage" and .type=="aws_dynamodb_table") | .change.after | {billing_mode, table_class, hash_key, range_key, attribute, ttl, point_in_time_recovery, server_side_encryption, deletion_protection_enabled}' tfplan.json

# 3. Bucket: force_destroy must be true in demo
jq '.resource_changes[] | select(.module_address=="module.storage" and .type=="aws_s3_bucket") | {bucket: .change.after.bucket, force_destroy: .change.after.force_destroy}' tfplan.json

# 4. SSE: aws:kms, bucket key, SSE-C blocked (key ARN is unknown if security is created in the same plan)
jq '.resource_changes[] | select(.module_address=="module.storage" and .type=="aws_s3_bucket_server_side_encryption_configuration") | {after: .change.after.rule, unknown: .change.after_unknown.rule}' tfplan.json

# 5. Lifecycle: one rule, no transition blocks
jq '.resource_changes[] | select(.module_address=="module.storage" and .type=="aws_s3_bucket_lifecycle_configuration") | .change.after.rule' tfplan.json

# 6. Public access block: all four true
jq '.resource_changes[] | select(.module_address=="module.storage" and .type=="aws_s3_bucket_public_access_block") | .change.after' tfplan.json
```

### Runtime (after your apply)

```bash
TABLE=$(terraform output -raw hot_table_name)
BUCKET=$(terraform output -raw cold_bucket_id)

# Table configuration
aws dynamodb describe-table --table-name "$TABLE" \
  --query 'Table.{SSE:SSEDescription,Protection:DeletionProtectionEnabled,Billing:BillingModeSummary,Keys:KeySchema}'
aws dynamodb describe-time-to-live   --table-name "$TABLE"
aws dynamodb describe-continuous-backups --table-name "$TABLE"

# Dedup guard: the second put must fail with ConditionalCheckFailedException
cat > /tmp/item.json <<'EOF'
{"pk": {"S": "DEV#verify-01"}, "sk": {"S": "SEQ#000000000001"}, "expires_at": {"N": "4102444800"}}
EOF
aws dynamodb put-item --table-name "$TABLE" --item file:///tmp/item.json --condition-expression 'attribute_not_exists(pk)'
aws dynamodb put-item --table-name "$TABLE" --item file:///tmp/item.json --condition-expression 'attribute_not_exists(pk)'

# Bucket configuration
aws s3api get-bucket-encryption            --bucket "$BUCKET"
aws s3api get-bucket-versioning            --bucket "$BUCKET"
aws s3api get-public-access-block          --bucket "$BUCKET"
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET"
aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text | jq .
aws s3api get-bucket-ownership-controls    --bucket "$BUCKET"   # expect BucketOwnerEnforced (not declared in code)

# Default encryption applies the CMK with a bucket key; write the same key twice -> 2 versions
echo '{"verify":true}' > /tmp/obj.json
aws s3api put-object --bucket "$BUCKET" --key telemetry/dt=2026-01-01/hour=00/verify-01-000000000001.json --body /tmp/obj.json
aws s3api put-object --bucket "$BUCKET" --key telemetry/dt=2026-01-01/hour=00/verify-01-000000000001.json --body /tmp/obj.json
aws s3api head-object --bucket "$BUCKET" --key telemetry/dt=2026-01-01/hour=00/verify-01-000000000001.json
aws s3api list-object-versions --bucket "$BUCKET" --prefix telemetry/ --query 'Versions[].{Key:Key,Id:VersionId,Latest:IsLatest}'

# TLS-only: plain-HTTP request must be denied (403)
aws s3api head-object --bucket "$BUCKET" --key telemetry/dt=2026-01-01/hour=00/verify-01-000000000001.json \
  --endpoint-url http://s3.us-east-1.amazonaws.com
```

Then capture evidence in `docs/evidence/` and destroy with
`terraform destroy -var-file=demo.tfvars -target=module.storage -target=module.security`.
The destroy itself is a test: it must succeed with two object versions in
the bucket (proves `force_destroy` handles noncurrent versions).

## Not verified yet

- KMS actions beyond `Decrypt` (DynamoDB) and `GenerateDataKey` (S3) for the
  ingest role — settled by the first `ingest` runtime test.
- That `force_destroy` removes noncurrent versions — settled by the destroy
  above.
- That the Trivy ID `aws-s3-enable-logging` matches the check Trivy reports
  on this bucket; if the finding still shows, copy the ID Trivy prints.
- That `blocked_encryption_types` exists in the provider version pinned in
  `.terraform.lock.hcl` (it is in the current 6.x docs). If `validate`
  reports *Unsupported argument*, run `terraform init -upgrade`.
- Object ownership default (`BucketOwnerEnforced`) — checked at runtime, not
  declared.
