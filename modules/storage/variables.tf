# Three inputs only. Everything that is identical in demo and prod (PITR,
# key schema, TTL attribute, noncurrent-version retention, lifecycle
# hygiene) is a local in main.tf, not a variable (ADR-0002, ADR-0013).

variable "name_prefix" {
  description = "Pre-assembled resource name prefix (e.g. pyrosense-demo). The module never builds it."
  type        = string

  # Same contract as security and messaging. The S3 bucket name derived
  # from it has a tighter 63-character limit; that is enforced by a
  # precondition on the computed name, not by a hand-computed number here.
  validation {
    condition     = can(regex("^[a-z0-9-]{1,64}$", var.name_prefix))
    error_message = "name_prefix must be 1-64 characters of lowercase letters, digits and hyphens."
  }
}

variable "kms_key_arn" {
  description = "ARN of the pipeline CMK (module.security.kms_key_arn). Encrypts the DynamoDB table and is the S3 default-encryption key."
  type        = string

  # A full key ARN, never an alias or bare key id: S3 resolves an alias in
  # the *requester's* account, and the ingest IAM policy must name the key
  # ARN. If messaging's regex differs, align both to one literal.
  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/(mrk-[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<key-id>), not an alias or key id."
  }
}

variable "allow_data_destruction" {
  description = "true = `terraform destroy` may delete stored data (DynamoDB deletion protection off, S3 force_destroy on). Demo only; prod must be false."
  type        = bool

  # No default on purpose: the caller must state the intent. A default of
  # true would make prod destructible by omission; a default of false
  # would break the demo deploy -> evidence -> destroy cycle (ADR-0002).
}
