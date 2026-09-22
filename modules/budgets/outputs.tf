output "budget_name" {
  description = "Name of the recurring monthly cost budget."
  value       = aws_budgets_budget.monthly_cost.name
}

output "budget_arn" {
  description = "ARN of the recurring monthly cost budget."
  value       = aws_budgets_budget.monthly_cost.arn
}
