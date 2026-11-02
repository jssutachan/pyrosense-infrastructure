output "budget_name" {
  description = "Name of the account-wide monthly budget, for aws budgets describe-budget --budget-name."
  value       = module.budgets.budget_name
}

output "budget_arn" {
  description = "ARN of the account monthly cost budget."
  value       = module.budgets.budget_arn
}
