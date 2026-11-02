# -----------------------------------------------------------------------------
# bootstrap/finops: the account's cost guardrail (ADR-0003, ADR-0025)
#
# Why the budget is not in the main configuration any more: the main state
# holds the demo environment, which the pipeline creates and destroys every
# cycle (ADR-0002). The budget must survive every destroy, and the pipeline's
# apply role has no budgets write permission on purpose. Keeping it in the
# same state would force every destroy to exclude it (-target lists that rot
# as modules are added). In its own stack, "destroy demo" means "destroy
# everything in the main state", with no exception to remember.
#
# Long-lived and applied by the operator, like the other bootstrap stacks.
# In a production organisation this is where an account baseline puts its
# budgets: owned by the platform, not by the workload it watches.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  # The name the budget already has, so it is imported, not replaced:
  # renaming a budget recreates it (ADR-0024, provocation P2). The budget is
  # account-wide; "demo" in its name is historical.
  name_prefix = "${var.resource_prefix}-demo"
}

# One-time adoption of the budget created by the main configuration. Once the
# budget is in this state the block is a no-op, so it stays as the record of
# where the resource came from.
import {
  to = module.budgets.aws_budgets_budget.monthly_cost
  id = "${data.aws_caller_identity.current.account_id}:${local.name_prefix}-monthly-cost"
}

module "budgets" {
  source = "../../modules/budgets"

  name_prefix         = local.name_prefix
  limit_usd           = var.budget_limit_usd
  notification_emails = values(var.ops_recipients)
}
