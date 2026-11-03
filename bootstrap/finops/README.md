# bootstrap/finops

The account's cost guardrail: one AWS Budget, account-wide, with email
alerts (ADR-0003). It is the only PyroSense resource that is always on.

## Why a separate stack

| | Main configuration | `bootstrap/finops` |
|---|---|---|
| Holds | the `demo` environment | the account budget |
| Lifetime | one test cycle (ADR-0002) | permanent |
| Applied by | the pipeline, behind an approval (C4) | the operator |
| State key | `pyrosense/terraform.tfstate` | `bootstrap/finops/terraform.tfstate` |
| Pipeline access | plan role reads, apply role writes | none |

Until C4 the budget lived in the main state. A pipeline that destroys `demo`
would then have to exclude it on every destroy. Moving it here makes
"destroy demo" mean "destroy the whole main state" (ADR-0025, decision D1).
The module is unchanged: this stack calls `modules/budgets`.

## Use

```bash
cp bootstrap/finops/finops.tfvars.example bootstrap/finops/finops.tfvars   # then edit the address
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
terraform -chdir=bootstrap/finops init -backend-config="bucket=pyrosense-tfstate-${ACCOUNT_ID}"
terraform -chdir=bootstrap/finops plan  -var-file=finops.tfvars
terraform -chdir=bootstrap/finops apply -var-file=finops.tfvars
```

The first apply **imports** the budget that the main configuration created
(the `import` block in `main.tf`); it does not create a second one. The plan
must read `1 to import, 0 to add, 1 to change, 0 to destroy`:
the one change is the tags, from the main configuration's to this stack's.

Budgets are free while they have no budget actions; this one has none.
