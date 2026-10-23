# Role ARNs go to GitHub as SECRETS, not variables: a `with:` input that is
# not a secret is printed in the public workflow log, and the ARN contains
# the account id (docs/ci-cd.md, section 8).

output "plan_role_arn" {
  description = "Role for terraform plan in pull requests. Store as the repository secret AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role for apply/destroy of the deploy environment. Store as the secret AWS_APPLY_ROLE_ARN of that GitHub environment."
  value       = aws_iam_role.apply.arn
}

output "workload_boundary_arn" {
  description = "Permissions boundary every role created by the pipeline must carry. The main configuration reads it by name."
  value       = aws_iam_policy.workload_boundary.arn
}

output "github_sub_prefix" {
  description = "Subject prefix the trust policies expect. Must match the sub printed by the OIDC probe workflow."
  value       = local.github_sub_prefix
}
