variable "aws_region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d$", var.aws_region))
    error_message = "aws_region must look like 'us-east-1' (geo-direction-number)."
  }
}
