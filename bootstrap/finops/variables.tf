variable "aws_region" {
  description = "Region of the provider and of the state bucket. Budgets are global; this only selects the API endpoint."
  type        = string
  default     = "us-east-1"
}

variable "resource_prefix" {
  description = "Project identifier, the same as in the main configuration."
  type        = string
  default     = "pyrosense"
}

# $2 is deliberately tight: the deployment model is turn on, demonstrate,
# destroy, so sustained spend means something was left running. A KMS key left
# alive for a full month is $1, enough to trip the 80 % ACTUAL threshold.
variable "budget_limit_usd" {
  description = "Account-wide monthly cost ceiling in USD (ADR-0003)."
  type        = number
  default     = 2

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be greater than 0."
  }
}

# Same shape and label as the main configuration's ops_recipients, so one
# person reads both. Kept in the gitignored finops.tfvars.
variable "ops_recipients" {
  description = "Budget notification recipients as { label = email }. Gitignored finops.tfvars; see finops.tfvars.example."
  type        = map(string)
  sensitive   = true

  validation {
    condition     = length(var.ops_recipients) > 0
    error_message = "At least one budget recipient is required: a budget nobody reads is not a guardrail."
  }
}
