# Bootstrap

A standalone Terraform root that provisions the S3 bucket backing the remote
state of the main configuration.

## Why it is separate

The main configuration stores its state in S3, but that bucket has to exist
before `terraform init` can succeed. This is a chicken-and-egg problem, and
isolating it here is the resolution: this root is applied once, with local
state, before anything else.

Its own state file is intentionally small and disposable. Losing it does not
lose the bucket.

## What it creates

| Resource | Purpose |
|---|---|
| `aws_s3_bucket.state` | The state bucket, named with the account ID suffix. `prevent_destroy` guards against accidental deletion. |
| `aws_s3_bucket_versioning` | Every state push is recoverable by version rollback. |
| `aws_s3_bucket_server_side_encryption_configuration` | SSE-S3 (`AES256`) — see the encryption note below. |
| `aws_s3_bucket_public_access_block` | All four blocks enabled. |
| `aws_s3_bucket_policy` | Denies any request where `aws:SecureTransport` is false. |
| `aws_s3_bucket_lifecycle_configuration` | Expires noncurrent versions after 90 days. |

Locking uses the native S3 lockfile (`use_lockfile = true`, Terraform >= 1.11),
so there is no DynamoDB lock table.

## Why SSE-S3 and not the pipeline CMK

Two reasons, both in ADR-0001:

1. **Bootstrap ordering.** This stack runs before any project CMK exists.
   Encrypting its own state bucket with a CMK would stack a second
   chicken-and-egg dependency on top of the first.
2. **Failure mode.** If state were encrypted with a CMK and that key were ever
   scheduled for deletion or lost, the state — the map of every deployed
   resource — would become unreadable. SSE-S3 has no such failure mode.

The pipeline CMK created by `modules/security` (ADR-0010) encrypts application
data. It deliberately does not reach here.

## Trivy suppressions

Two findings are suppressed inline, each with its rationale in the source.

| Report ID | Internal rule name | Why suppressed |
|---|---|---|
| `AWS-0089` | `aws-s3-enable-logging` | One consumer (Terraform); CloudTrail covers API-level auditing; a logging target bucket would trigger the same rule with no terminating case. |
| `AVD-AWS-0132` | `aws-s3-encryption-customer-key` | SSE-S3 over CMK, per ADR-0001. |

> **The report ID and the internal rule name are different strings.** The
> summary table prints `AWS-0089`, while the suppression matches a rule called
> `aws-s3-enable-logging`. Both suppressions above use the `AVD-` prefix and
> both match. Do not assume a suppression works because the table shows `0` —
> a parse error also shows `0`. Confirm with:
>
> ```bash
> trivy config . --tf-vars demo.tfvars 2>&1 | grep "Ignore finding"
> ```
>
> Expect one `Ignore finding` line per suppression.

Both were confirmed against trivy 0.71.2 on 2026-09-22.

## Usage

Applied once, manually, at project setup. Not part of CI/CD.

```bash
cd bootstrap/state-backend
terraform init      # local state, no backend block
terraform apply
```

Then copy `config/backend.hcl.example` to `config/backend.hcl`, fill in the
bucket name it printed, and run `terraform init -backend-config=config/backend.hcl`
from the repository root.

`prevent_destroy = true` means `terraform destroy` on this stack **fails by
design**. Removing the bucket requires deliberately editing the lifecycle block
first — which is the point.
