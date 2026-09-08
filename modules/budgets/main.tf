# FinOps guardrail — account-level monthly cost budget with email alerts.
#
# Account-wide (not tag-filtered) by design: a tag-scoped budget can't see
# untagged resources — exactly the mistakes this guardrail exists to catch.
#
# Cost: $0. Monitoring-only budgets are free; no budget actions are set
# (actions are the billable feature).

resource "aws_budgets_budget" "monthly_cost" {
  name         = "${var.name_prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    # Excluding credits (var default) tracks gross consumption; otherwise
    # free-tier credits mask spend and the net figure reads ~$0.
    include_credit = var.include_credits

    # Excluding refunds: counting them would understate consumption.
    include_refund = false
  }

  # ACTUAL: spend already crossed the threshold.
  dynamic "notification" {
    for_each = toset(var.actual_threshold_percents)

    content {
      notification_type          = "ACTUAL"
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.notification_emails
    }
  }

  # FORECASTED: the primary signal. Budget data refreshes only every ~8-12h,
  # so a projection is what warns while there's still time to act.
  notification {
    notification_type          = "FORECASTED"
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.forecasted_threshold_percent
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = var.notification_emails
  }
}
