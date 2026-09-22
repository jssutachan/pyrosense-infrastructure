variable "name_prefix" {
  description = "Resource name prefix, e.g. pyrosense-demo."
  type        = string

  validation {
    condition     = length(trimspace(var.name_prefix)) > 0
    error_message = "name_prefix must not be empty or whitespace."
  }
}

variable "limit_usd" {
  description = "Monthly cost limit in USD that the recurring notifications are measured against."
  type        = number

  validation {
    condition     = var.limit_usd > 0
    error_message = "limit_usd must be greater than zero."
  }
}

variable "include_credits" {
  description = <<-EOT
    Whether promotional credits offset the measured spend. AWS defaults this
    to true, which makes a budget silent while credits cover the bill: usage
    is real but net cost reads $0 and no notification ever fires. Keep it
    false to measure gross consumption, which is the number that tells you
    how fast a credit balance is being burned. Set it to true only once the
    account pays its own way and the question becomes "what will I be
    invoiced?" instead of "what am I consuming?".
  EOT
  type        = bool
  default     = false
}

variable "actual_threshold_percents" {
  description = "Percentages of limit_usd at which an ACTUAL-spend notification fires."
  type        = list(number)
  default     = [80, 100]

  validation {
    condition     = length(var.actual_threshold_percents) > 0
    error_message = "actual_threshold_percents must contain at least one threshold."
  }

  validation {
    condition     = alltrue([for pct in var.actual_threshold_percents : pct > 0])
    error_message = "Every threshold in actual_threshold_percents must be greater than zero."
  }
}

variable "notification_emails" {
  description = "Email addresses that receive budget notifications. AWS requires at least one subscriber per notification. Unlike SNS, budget subscribers are not asked to confirm."
  type        = list(string)

  validation {
    condition     = length(var.notification_emails) > 0
    error_message = "notification_emails must contain at least one address."
  }

  validation {
    condition = alltrue([
      for email in var.notification_emails :
      can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))
    ])
    error_message = "Every entry in notification_emails must be a valid email address."
  }
}

variable "forecasted_threshold_percent" {
  description = "Percentage of limit_usd at which a FORECASTED-spend notification fires. This is the early warning: AWS projects month-end spend before the money is gone."
  type        = number
  default     = 100

  validation {
    condition     = var.forecasted_threshold_percent > 0
    error_message = "forecasted_threshold_percent must be greater than zero."
  }
}
