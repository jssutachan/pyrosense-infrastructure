# Root input contract. Values arrive from demo.tfvars / prod.tfvars.
# NOTE: aws_region and environment are consumed by providers.tf (region and
# default_tags), not by main.tf — that's why they look "unused" here.

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment. Drives resource naming and default_tags."
  type        = string

  validation {
    condition     = contains(["demo", "prod"], var.environment)
    error_message = "environment must be either 'demo' or 'prod'."
  }
}

variable "resource_prefix" {
  description = "Base name prefix for all resources, e.g. 'pyrosense'."
  type        = string
  default     = "pyrosense"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.resource_prefix))
    error_message = "resource_prefix must be lowercase alphanumeric and hyphens only."
  }
}

variable "budget_limit_usd" {
  description = "Monthly account cost budget in USD. Set per environment in tfvars."
  type        = number
}

variable "ops_emails" {
  description = "Recipients for budget alerts. At least one required (enforced in the budgets module)."
  type        = list(string)
}
