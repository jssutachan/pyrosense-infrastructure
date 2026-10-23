# bootstrap/ci-identity

The AWS identity of the CI/CD pipeline: a GitHub OIDC identity provider, a
read-only **plan** role, an **apply** role limited to `pyrosense-demo-*`, and
the **workload permissions boundary** every pipeline-created role must carry.

Why it is built this way: [ADR-0023](../../docs/adr/0023-pipeline-identity-oidc-and-workload-boundary.md)
and [docs/ci-cd.md, section 8](../../docs/ci-cd.md#8-pipeline-identity-c2).

| File | Contents |
|---|---|
| `main.tf` | identity provider, trust policies (who may assume), roles, attachments |
| `boundary.tf` | the workload permissions boundary |
| `permissions.tf` | what each role may do: read, state, apply (data, infra, IAM) |

This stack is applied by the operator, with administrator credentials. The
pipeline cannot change it: the apply role is denied every IAM write on the
pipeline's own roles, policies and identity provider.

## Prerequisites

- `bootstrap/state-backend` applied (the state bucket exists).
- The repository emits the **immutable** OIDC subject. Repositories created on
  or after 2026-07-15 do by default. For an older repository, opt in once:

  ```bash
  gh api -X PUT repos/<owner>/<repo>/actions/oidc/customization/sub \
    -F use_default=true -F use_immutable_subject=true
  ```

- No GitHub identity provider in the account yet (there can be only one per
  URL): `aws iam list-open-id-connect-providers` must not list
  `token.actions.githubusercontent.com`. If it does, import it instead of
  creating it.

## First apply

```bash
cp bootstrap/ci-identity/backend.hcl.example bootstrap/ci-identity/backend.hcl
cp bootstrap/ci-identity/terraform.tfvars.example bootstrap/ci-identity/terraform.tfvars
# fill in both files (neither is committed)

terraform -chdir=bootstrap/ci-identity init -backend-config=backend.hcl
terraform -chdir=bootstrap/ci-identity plan -out=ci-identity.tfplan
terraform -chdir=bootstrap/ci-identity apply ci-identity.tfplan
rm bootstrap/ci-identity/ci-identity.tfplan
```

Expected: `17 to add, 0 to change, 0 to destroy` (1 identity provider,
2 roles, 7 managed policies, 7 attachments). IAM roles, policies and
identity providers have no charge.

Then configure GitHub with the outputs (values never go into the repository):

```bash
terraform -chdir=bootstrap/ci-identity output -raw plan_role_arn  | gh secret set AWS_PLAN_ROLE_ARN
terraform -chdir=bootstrap/ci-identity output -raw apply_role_arn | gh secret set AWS_APPLY_ROLE_ARN --env demo
```

The `demo` environment needs, in **Settings → Environments → demo**: the
maintainer as required reviewer, and deployment branches limited to the
default branch.

## Changing permissions

- **A workload role needs a new action** (for example a module starts calling
  a new SQS API): add it to the module's policy *and*, if the project has never
  used it, to `boundary.tf`. Apply this stack first. Without the boundary
  change, the module's role gets `AccessDenied` at runtime.
- **The pipeline gets `AccessDenied`** in plan or apply: add the exact action
  to `permissions.tf`, in the statement whose scope fits, with a comment if
  the reason is not obvious. Never widen to a service wildcard.

Every change here is a pull request like any other, then an operator apply.

## Destroying

Not part of any cycle. The identity provider has `prevent_destroy`; removing
it breaks every pipeline role at once.
