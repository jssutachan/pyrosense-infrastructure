# ADR-0024: Terraform plan in pull requests

- **Status:** Accepted (2026-11-01, after the C3 run)
- **Date:** 2026-11-01
- **Stage:** CI/CD, sub-stage C3 (plan in pull requests)
- **Evidence:** [docs/evidence/ci-c3-2026-11-01/](../evidence/ci-c3-2026-11-01/README.md)

## Context

C1 verifies every pull request statically, and C2 gave the pipeline a
read-only AWS role. Nothing yet tells a reviewer what a change would **do** to
AWS before it is merged. Until now that was a manual `terraform plan` on the
operator's machine.

Facts that shaped the decision:

- **The plan's inputs live on one laptop.** `demo.tfvars` is gitignored
  because it holds email addresses (PII). It also holds values that are not
  sensitive at all: the environment name, the budget, the KMS deletion window,
  `allow_data_destruction`. The IoT CSR is read from a file path on that
  machine. When the laptop was reinstalled in October, the CSR and its key
  were lost.
- **The budget is always deployed.** It notifies `ops_recipients`, so a
  plan run with different recipients than the real ones shows a change to a
  live resource.
- **The repository and its logs are public.** Terraform's text output
  prints ARNs, which contain the account id, and the IoT endpoint.
  `terraform show -json` includes every attribute value. Sensitive ones are
  only flagged in `before_sensitive`/`after_sensitive`, not removed.
- **Artifacts are not private.** Anyone signed in to GitHub with read
  access can download a workflow artifact, and on a public repository that
  is everyone.
- **Required checks interact with skipping.** A job skipped by an `if:`
  reports success for a required status check. A workflow skipped by a
  `paths:` filter leaves the check pending and blocks the merge.
- **No OIDC token outside the maintainer's runs.** Pull requests from
  forks and from Dependabot get no secrets and a read-only token.
  The plan role also trusts only the maintainer's `actor_id` (ADR-0023).
- **`demo` is ephemeral (ADR-0002).** Between cycles only the budget exists,
  so most plans show the whole stack as "create".

## Decision

**D1. Every pull request to `develop` or `main` runs `terraform plan` against
`demo` as the required check `plan`**, with the plan role from ADR-0023.
There is no `paths:` filter. The job is skipped, which counts as success,
only for pull requests from forks or from Dependabot, where no OIDC token can
exist.

**D2. Plan inputs come in two layers.**
1. `demo.tfvars.example` is committed and holds every non-sensitive value.
2. A sensitive layer overrides its placeholders: the recipients and the CSR
   path.
   - **Locally**, the gitignored `demo.tfvars` holds only those three
     values.
   - **In CI**, the recipients come from the secrets `DEMO_OPS_RECIPIENTS`
     and `DEMO_FIRE_ALERT_RECIPIENTS` (JSON objects), and the CSR from the
     repository variable `DEMO_IOT_FLEET_CLIENT_CSR`.

`make plan`, `make apply` and `make destroy` pass both files in that order. CI
does the same with a JSON file it builds at run time. A later `-var-file`
overrides an earlier one.

**D3. The CSR is a variable, not a secret.** It holds a public key and a
name, and the certificate AWS issues from it is public too. The private key
never leaves the operator's machine (ADR-0017). The CSR stays out of the
repository only because the guard refuses tracked `*.csr` files.

**D4. Backend settings come from the committed `config/backend.hcl.example`.**
Only the bucket name, which carries the account id, is computed at run time
from the assumed role.

**D5. Only addresses and actions reach the log.** The text output of plan and
init goes to a file on the runner. An error is shown through a redaction
filter (`scripts/ci/redact.sh`). The job summary is built from the plan's JSON
by `scripts/ci/plan-summary.sh`, which reads two fields per resource:
`address` and `change.actions`. Destroys and replaces are highlighted.

**D6. The plan file is never kept.** No artifact is uploaded and the files
are deleted at the end of the job. The plan in a pull request is
informational. C4 will plan again in the approved deploy job and apply that
plan.

**D7. A running plan is never cancelled.** It holds the state lock, and a
cancelled job leaves the lock file in S3. Runs of the same pull request queue
(`cancel-in-progress: false`). Runs of different pull requests wait for the
lock for up to five minutes (`-lock-timeout=5m`).

## Rationale

- **Plan in the pull request is the standard review practice for Terraform**
  (HCP Terraform, Atlantis, Spacelift all centre on it). The reviewer judges
  the effect, not only the code.
- **The two layers make the committed file the single source of every value
  a reader may see.** Secrets stay where secrets belong. CI and the operator
  cannot drift on non-sensitive values, because both read the same file.
- **Reading two fields of the JSON is a guarantee, not a convention.** A
  summary that never touches attribute values cannot leak one, whatever a
  future module adds.
- **A summary needs no write permission.** A pull request comment would need
  `pull-requests: write` on a job that also holds AWS credentials. The job
  summary keeps the workflow token read-only.

## Alternatives considered

| Alternative | Why not |
|---|---|
| The whole `demo.tfvars` as one multi-line secret | Simplest, but the non-sensitive values become invisible to reviewers, and log masking of multi-line values is a known weak spot (it is reported to work line by line, which would star out short lines such as `}` across every log) |
| Every variable as a separate `TF_VAR_*` secret | Environment variables have the lowest precedence, below any `-var-file`, so the committed placeholders would win. It also needs more secrets than the two that are actually sensitive |
| Upload the plan as an artifact and apply it in C4 | The plan file holds the recipients in clear text, and artifacts of a public repository can be downloaded by anyone signed in |
| Plan output as a pull request comment | Better visibility on the conversation tab, but it needs `pull-requests: write` beside AWS credentials, and the text output would need careful redaction |
| `paths:` filter (plan only when Terraform changes) | A filtered-out required check never reports and blocks the merge (ADR-0022) |
| Commit the CSR | Harmless in itself, but it means an exception to the guard's rule against tracked key material, which is worth more as an absolute rule |

## Consequences

- Before C3 runs, the operator regenerates the fleet client's key and CSR
  (lost in the October reinstall). The CSR goes into the GitHub variable and
  the local path. The key stays on the operator's machine.
- The local `demo.tfvars` shrinks to the three sensitive values. A value
  left in it would override the committed one locally and make the operator's
  plan differ from CI's.
- Changing a recipient means updating two places: the local file and the
  GitHub secret. Labels must match between the committed placeholders and the
  real values, or subscriptions appear as replaced.
- The plan role's read permissions are exercised for the first time. An
  `AccessDenied` is fixed in `bootstrap/ci-identity` by the operator
  (ADR-0023, D8).
- `docs/github/ruleset-protected-branches.json` gains the required check
  `plan`.
- A pull request from a fork or from Dependabot merges without a plan. The
  plan of the next maintainer pull request, or the scheduled drift check of
  C5, covers it.

## Validation

Proven on 2026-11-01:
- **The first CI plan matched the operator's plan exactly.** Both reported
  50 create and the budget unchanged, and the plan role needed no extra
  permission.
- **An invalid value in the committed inputs failed `plan`** and blocked the
  merge, while the static checks stayed green.
- **Renaming the always-on budget was flagged** as a replace at the top of the
  summary.
- **The plan-run logs are clean:** no account id and no email in 1,589 lines.

## Revisit if

- A second maintainer joins: the plan role's `actor_id` list, and whether
  pull request comments are worth the write permission.
- `demo` stops being ephemeral, or a long-lived environment is added: plans
  then show real diffs, and a plan per environment may be needed.
- GitHub makes artifacts of public repositories private, or a plan-file
  encryption step is added: then C4 could apply the reviewed plan file.
