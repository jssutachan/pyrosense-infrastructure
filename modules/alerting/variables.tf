variable "name_prefix" {
  description = "Resource name prefix, already assembled by the root (e.g. pyrosense-demo). Topics are named <name_prefix>-fire-alerts and <name_prefix>-ops-alarms."
  type        = string

  # Same contract as security/messaging/storage. SNS allows 1-256 characters
  # of [A-Za-z0-9_-]; 64 plus the longest suffix (-fire-alerts) stays far
  # below 256, so no precondition on the derived names is needed.
  validation {
    condition     = can(regex("^[a-z0-9-]{1,64}$", var.name_prefix))
    error_message = "name_prefix must be 1-64 characters of lowercase letters, digits and hyphens."
  }
}

variable "kms_key_arn" {
  description = "ARN of the pipeline CMK (module.security.kms_key_arn). Encrypts both topics at rest; the ingest role's KMS grants must name this same ARN."
  type        = string

  # A key ARN, not an alias or key id: IAM policies in the ingest module must
  # name the full key ARN, so accepting anything else here would let the two
  # drift. Tech debt #21: align this literal with the one in messaging.
  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/(mrk-[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>), not an alias or a bare key id."
  }
}

variable "fire_alert_recipients" {
  description = "Fire-risk alert recipients as { label = email }. Labels (e.g. \"duty-desk\") become resource addresses and appear in plans; addresses never do. Email is PII: supply it only from a gitignored tfvars (project standard #11)."
  type        = map(string)
  sensitive   = true

  # A topic nobody is subscribed to accepts every publish and delivers
  # nothing. For the fire topic that is the silent failure the platform
  # exists to prevent, so an empty map fails at plan.
  validation {
    condition     = length(var.fire_alert_recipients) > 0
    error_message = "fire_alert_recipients must contain at least one recipient."
  }

  validation {
    condition     = alltrue([for label in keys(var.fire_alert_recipients) : can(regex("^[a-z0-9-]{1,64}$", label))])
    error_message = "Every fire_alert_recipients label must be 1-64 lowercase letters, digits or hyphens (labels are shown in plans; never use an address as a label)."
  }

  # Same literal as modules/budgets (notification_emails): one contract for
  # what an address is.
  validation {
    condition     = alltrue([for email in values(var.fire_alert_recipients) : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))])
    error_message = "Every fire_alert_recipients value must be a valid email address."
  }

  # Two labels for one address would be two Terraform resources managing the
  # same SNS subscription: destroying either one unsubscribes both.
  validation {
    condition     = length(distinct([for email in values(var.fire_alert_recipients) : lower(email)])) == length(var.fire_alert_recipients)
    error_message = "fire_alert_recipients must not list the same address twice (comparison is case-insensitive)."
  }
}

variable "ops_recipients" {
  description = "Operational alarm recipients as { label = email }. Same shape and rules as fire_alert_recipients. Email is PII: supply it only from a gitignored tfvars (project standard #11)."
  type        = map(string)
  sensitive   = true

  # An alarm that notifies nobody is a mechanism that never runs.
  validation {
    condition     = length(var.ops_recipients) > 0
    error_message = "ops_recipients must contain at least one recipient."
  }

  validation {
    condition     = alltrue([for label in keys(var.ops_recipients) : can(regex("^[a-z0-9-]{1,64}$", label))])
    error_message = "Every ops_recipients label must be 1-64 lowercase letters, digits or hyphens (labels are shown in plans; never use an address as a label)."
  }

  validation {
    condition     = alltrue([for email in values(var.ops_recipients) : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))])
    error_message = "Every ops_recipients value must be a valid email address."
  }

  validation {
    condition     = length(distinct([for email in values(var.ops_recipients) : lower(email)])) == length(var.ops_recipients)
    error_message = "ops_recipients must not list the same address twice (comparison is case-insensitive)."
  }
}
