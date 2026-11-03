# ADR-0025: Manual delivery to `demo` from the pipeline

- **Status:** Accepted
- **Date:** 2026-11-01 (proposed) · 2026-11-03 (accepted, after the first deliveries)
- **Related:** ADR-0002 (design for production, deploy for demo), ADR-0003 (budget),
  ADR-0010 (single CMK), ADR-0015 (email alerts), ADR-0017 (device identity),
  ADR-0023 (pipeline identity), ADR-0024 (plan in pull requests)
- **Evidence:** [docs/evidence/ci-c4-2026-11-03/](../evidence/ci-c4-2026-11-03/README.md)

## Context

C1 to C3 verify every change; the operator still deployed and destroyed `demo`
from a laptop with personal credentials. C4 moves that to the pipeline, with
the apply role built in C2, whose write permissions had never been exercised.

Constraints:
- `demo` is ephemeral: each cycle creates about 50 resources, tests them and
  destroys them. Only the account budget is always on, and the apply role has
  no budgets permission.
- The repository and its logs are public. A plan holds the recipients' email
  addresses in clear text; ARNs carry the account id.
- The GitHub environment `demo` already requires the maintainer's approval,
  accepts `main` only and has no administrator bypass.
- Email subscriptions need a person to confirm them after every apply.
- One maintainer: the person who dispatches is the person who approves.

## Decisions

### D1. The budget moves to its own stack, `bootstrap/finops`

The budget is imported into a long-lived, operator-applied stack with its own
state key, which neither pipeline role can read or write. The main state then
holds only what one cycle creates, so `destroy` destroys all of it.

| Option | Rejected because |
|---|---|
| `terraform destroy -target=module.x` for every module except `budgets` | Terraform documents `-target` for exceptional use; the list must change every time a module is added, and forgetting one leaves it running |
| `lifecycle { prevent_destroy = true }` on the budget | It does not skip the resource: it makes the whole destroy fail |
| `removed { lifecycle { destroy = false } }` in the main configuration | It forgets the budget once; it does not exclude it from every later destroy |
| Keep it, and give the apply role budgets permissions | The always-on guardrail would be writable by the pipeline it watches |

This is also where a production organisation keeps budgets: in the account
baseline owned by the platform, not in the workload. The migration is a
one-time operator step: import into the new stack, then `terraform state rm`
from the main state. It was preferred to a `removed` block because the
`forget` action it produces in a plan's JSON is not in the documented action
list, and `scripts/ci/plan_guard.py` refuses unknown actions.

### D2. Two plans, one fingerprint: the reviewer approves what they read

`deploy.yml` has three jobs: `preflight` (no credentials), `plan` (plan role,
no environment) and `deliver` (apply role, environment `demo`). The `plan` job
writes the summary before the approval is requested, so the reviewer reads the
plan and then approves. `deliver` plans again and applies only if the second
plan has the same fingerprint: a SHA-256 over every managed resource address
and its actions, never over values.

| Option | Rejected because |
|---|---|
| One job: approve, then plan and apply | The approval is given blind; the plan is shown only after it |
| Plan in one job, upload the plan file, apply it in another | The plan file holds the recipients in clear text, and artifacts of a public repository are downloadable by anyone signed in |
| A second approval between plan and apply | One maintainer would approve twice with the same knowledge; the fingerprint check adds safety, a second click adds none |

The plan role gains one trust statement: `sub` = `…:ref:refs/heads/main` and
`job_workflow_ref` = `deploy.yml@refs/heads/main`. It stays read-only.

### D3. A policy gate in code, not only in the reviewer's eyes

`scripts/ci/plan_guard.py`, unit tested, refuses:
- in `apply`: any delete, including the delete half of a replace, except the
  replacement of a resource left tainted by a failed apply;
- in `destroy`: anything other than delete;
- in both: any action it does not know (fail closed);
- in `apply`: creating a resource that is in the state but that the refresh
  could no longer read (`resource_drift` delete). Either it was deleted
  outside Terraform or the planning role lacks a read; a person decides.
  Tainted replacements are allowed and always reported as a warning.

An `apply` that would destroy something is never what a delivery means here;
that case goes back to the operator.

### D4. Trigger: `workflow_dispatch` on `main`, with a typed confirmation

Inputs: `operation` (`apply` or `destroy`) and `confirm`, which must repeat
the operation. `preflight` checks both and the branch before anyone is asked
to approve. Nothing runs on a merge: continuous delivery, not continuous
deployment.

### D5. The apply role trusts one workflow file

The apply role's trust policy adds `job_workflow_ref` =
`<owner>/<repo>/.github/workflows/deploy.yml@refs/heads/main`. Any workflow
that names the environment gets the environment `sub`; only this file gets
credentials. The `apply-role` job of `oidc-probe.yml` can no longer assume the
role, so its negative checks move into `deliver`, where they run before every
apply and destroy.

### D6. Concurrency: one delivery at a time; the state lock does the rest

`deploy.yml` has its own group (`deploy-demo`, `cancel-in-progress: false`).
Pull request plans are not in it: a delivery waiting hours for approval would
hold every review, and with the default queue a newer run cancels the pending
one. The S3 state lock serialises a plan and an apply on the same state;
`-lock-timeout=10m` makes the delivery wait instead of failing.

### D7. Verification after every operation

- `apply`: a second plan must be empty (convergence), then
  `scripts/ci/smoke-demo.sh` checks the control plane: function active,
  mapping enabled, certificate active with its policy, rule enabled, redrive
  to the DLQ, DLQ empty, key enabled and rotating, table and bucket encrypted,
  every alarm present, subscriptions present.
- `destroy`: a refresh-only plan reports drift before it (warning, not a
  block: refusing would leave a billed environment up), and the state must be
  empty after it.

The data path is not tested by the pipeline: publishing telemetry needs the
fleet client's private key, which never leaves the operator's machine
(ADR-0017). Giving the pipeline `iot:Publish` or `sqs:SendMessage` would break
the rule that it never touches data. The end-to-end test stays an operator
step after the subscriptions are confirmed.

### D8. Email confirmation stays human

The smoke test reports how many subscriptions are pending; the operator
confirms each one. Terraform cannot confirm an email subscription, and a
pending one is not a failed apply (ADR-0015).

### D9. The same log discipline as C3

Command output goes to files on the runner. The log shows only the plan
summary (addresses, actions and, for in-place updates, the names of the
changed attributes), the `Apply complete!` line, the guard's addresses and the
smoke test's PASS/FAIL lines. On failure, the last lines go through
`scripts/ci/redact.sh`. Nothing is uploaded; every plan file is deleted with
`if: always()`. The certificate PEM is a sensitive output and is never read
by the workflow.

### D10. A missing permission is a reasoned line, never a wildcard

The first deliveries exercise every write of the apply role and, for the
first time, every read of the plan role against live resources. Each failure
is fixed in `bootstrap/ci-identity` with the exact action, the tightest
resource scope that works, and a comment saying why.

## Validation (2026-11-03)

The first deliveries found four missing permissions. Two failed loudly; two
failed silently and were caught by the policy gate and by the reviewer.

| Found | How it showed | Fix |
|---|---|---|
| Apply role: `kms:CreateAlias` on the key | `AccessDenied`, apply 1 | alias actions in `ManageProjectKeys`; KMS authorises alias calls on the alias **and** on the key |
| Apply role: `lambda:TagResource` on the event source mapping | `AccessDenied`, apply 1 | `TagEnvironmentEventSourcesOnCreate`, scoped by the project and environment request tags |
| Plan role: `s3:ListBucket` (HeadBucket) on a live bucket | silent: the provider read the 403 as a deleted bucket, planned it as create and its five configuration resources as replace; `plan_guard` refused before any approval | `HeadEnvironmentBuckets` (this environment's buckets only); D3 gained the lost-resource rule |
| Plan role: `kms:Decrypt` of the function's environment through Lambda (ADR-0010 CMK) | silent: the refresh returned no variables, every plan updated the function; the reviewer rejected the plan because it differed from the operator's | `ReadEnvironmentFunctionConfiguration`: only via `lambda.<region>.amazonaws.com`, only for this environment's functions (`aws:lambda:FunctionArn` context), only on project keys |

After the fixes, the pipeline's plan was identical to the operator's local plan
of the same state, the apply converged, the 13 smoke checks passed, an
operator end-to-end test with the certificate issued by the pipeline reached
DynamoDB, S3 and the fire-alert mailbox, and the destroy left the main state
empty with the budget untouched.

## Consequences

- The operator no longer needs personal credentials to run a cycle; the
  laptop is still needed for the CSR's private key and the data test.
- A failed apply leaves a partial environment. It is resumed by dispatching
  `apply` again or removed with `destroy`; the operator's local `make destroy`
  remains the last resort.
- `bootstrap/finops` is a fourth long-lived stack the operator maintains.
- Neither pipeline role reads a budget any more, so `budgets:ViewBudget` and
  `budgets:ListTagsForResource` leave their shared read policy.
- The plan role is trusted by two contexts (pull requests and the deploy
  plan job), both read-only. Its read policy has one declared exception to
  "no decryption": the function's configuration, through Lambda only.

## Known limitations

- One maintainer dispatches and approves. A second reviewer is a production
  requirement (production readiness, section 9).
- `job_workflow_ref` pins the file, not its content: any change merged into
  `deploy.yml` on `main` is trusted. The ruleset's required checks are the
  control on that content.
- The smoke test checks configuration, not behaviour; behaviour is the
  operator's end-to-end test.
- The lost-resource rule of D3 is proven by unit tests only: once the
  permission was fixed, the situation could no longer be produced on AWS.
- The pre-destroy drift report cannot tell attributes AWS updates by itself
  (an event source mapping after processing messages) from a manual change.
- A run waiting for approval holds the delivery queue: a newer dispatch waits
  behind it, and a third one cancels the waiting second.
