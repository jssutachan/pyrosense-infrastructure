# Compares module.budgets before/after in a saved plan WITHOUT printing any
# email address. Usage: jq -f scripts/budget-check.jq tfplan.json
# Expected after the ops_emails -> ops_recipients change: actions ["update"],
# notification_values_equal true, other_attributes_equal true,
# sensitive_before false, sensitive_after true.
def norm: map(.subscriber_email_addresses |= ((. // []) | sort)
             | .subscriber_sns_topic_arns  |= ((. // []) | sort))
          | map(tojson) | sort;
.resource_changes[]
| select(.address == "module.budgets.aws_budgets_budget.monthly_cost")
| .change
| {
    actions:                     .actions,
    notification_values_equal:   ((.before.notification | norm) == (.after.notification | norm)),
    other_attributes_equal:      ((.before | del(.notification)) == (.after | del(.notification))),
    sensitive_before:            ([.before_sensitive.notification[]? | .subscriber_email_addresses? // false] | any),
    sensitive_after:             ([.after_sensitive.notification[]?  | .subscriber_email_addresses? // false] | any)
  }
