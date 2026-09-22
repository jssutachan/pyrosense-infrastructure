variable "name_prefix" {
  description = "Resource name prefix, e.g. pyrosense-demo. Used for the KMS alias and the key description."
  type        = string

  validation {
    # KMS alias names allow [a-zA-Z0-9:/_-]; we additionally forbid leading or
    # trailing hyphens so "alias/${name_prefix}-pipeline" never yields "--".
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with internal hyphens only, e.g. pyrosense-demo."
  }

  validation {
    # alias/ + name_prefix + -pipeline must stay under the 256-char alias limit,
    # and an overlong prefix is almost always a wiring mistake in the root.
    condition     = length(var.name_prefix) <= 64
    error_message = "name_prefix must be 64 characters or fewer."
  }
}

variable "deletion_window_days" {
  description = "Waiting period, in days, before AWS KMS permanently deletes the key after deletion is scheduled. Deletion is irreversible: every object encrypted under this key becomes unreadable. Demo uses the 7-day floor for fast teardown; production should use 30."
  type        = number
  default     = 7

  validation {
    # AWS rejects anything outside 7..30 at apply time. Catching it at plan
    # time turns a failed apply into a failed validate.
    condition     = var.deletion_window_days >= 7 && var.deletion_window_days <= 30
    error_message = "deletion_window_days must be between 7 and 30 inclusive (AWS KMS limit)."
  }
}
