# root/outputs.tf — surface the module's outputs at the root so
# `terraform output` shows them after apply (portfolio-grade: prove the result).
output "budget_arn" {
  description = "ARN of the account monthly cost budget."
  value       = module.budgets.budget_arn
}
