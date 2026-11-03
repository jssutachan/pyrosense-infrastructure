# Terraform plan in pull requests: evidence (C3, 2026-11-01)

This is the proof that the plan check described in
[docs/ci-cd.md, section 9](../../ci-cd.md#9-plan-in-pull-requests-c3) works:
- every pull request gets a real `terraform plan` of `demo`, run with the
  read-only role;
- it catches errors the static gate cannot see;
- it flags any change to the infrastructure that is alive;
- it leaks nothing into the public log.

Decision record: [ADR-0024](../../adr/ADR-0024-terraform-plan-in-pull-requests.md).

---

## Method

1. **Two input layers, checked locally first.** The operator's `demo.tfvars`
   was reduced to the three sensitive values. Before any other change, a
   local plan with both layers had to give the same result as before: 50
   resources to create, and the always-on budget unchanged.
2. **Configuration.** Two secrets were set for the recipient maps and one
   variable for the fleet client's CSR. The recipients were piped from
   `terraform console` straight into `gh secret set`, so no address appeared
   on screen. The CSR was regenerated, because the previous key pair was
   lost when the laptop was reinstalled.
3. **First CI run.** The pull request that introduced the check had to pass
   `plan` with the same summary as the local plan.
4. **Required check.** `plan` was added to the repository ruleset
   ([docs/github/ruleset-protected-branches.json](../../github/ruleset-protected-branches.json)).
5. **Provocations.** Two pull requests were built to exercise the check and
   closed without merging:
   - **P1** sets an invalid value in the committed inputs. `plan` must fail and
     the merge must be blocked, while the static checks stay green.
   - **P2** renames the always-on budget. `plan` must pass and its summary must
     flag the change before anyone merges it.
6. **Public logs.** The logs of the plan runs were searched for the account
   id and the operator's email.

## Results

### The first plan in CI equals the operator's plan

| Run | Create | Update | Replace | Destroy | Unchanged |
|---|---:|---:|---:|---:|---:|
| Local: operator credentials, `demo.tfvars.example` + `demo.tfvars` | 50 | 0 | 0 | 0 | 1 |
| CI: plan role, `demo.tfvars.example` + secrets | 50 | 0 | 0 | 0 | 1 |

`demo` was destroyed, so the 50 creates are the whole stack. The one
unchanged resource is the budget. It stays unchanged only if the CI plan
received the real recipients, because the budget notifies them. The plan
role needed **no** extra permission: the read set measured in C2 was enough
on the first run.

Sources: [raw/01-green-plan.txt](raw/01-green-plan.txt) and
[raw/06-local-vs-ci.txt](raw/06-local-vs-ci.txt).

### P1: an error only a plan can find

`kms_deletion_window_days = 3` was set in `demo.tfvars.example`:
- **`plan` failed** with `Invalid value for variable … must be between 7 and
  30 inclusive (AWS KMS limit)`;
- **the other four checks stayed green**, including `terraform`, because
  `terraform validate` does not read tfvars;
- **the merge was blocked.**

The error shown in the log names the file, the line and the value, and
nothing else. Source:
[raw/02-provocation-p1-invalid-value.txt](raw/02-provocation-p1-invalid-value.txt).

### P2: a change to the live infrastructure is flagged

The budget's name was changed in `modules/budgets`. `plan` **passed**, and
its summary opened with a warning:

```text
| Create | Update | Replace | Destroy | Unchanged |
|     50 |      0 |       1 |       0 |         0 |
> [!WARNING]
> This change destroys or replaces existing resources:
> - module.budgets.aws_budgets_budget.monthly_cost (replace)
```

Renaming a budget makes AWS replace it rather than update it. The check is
informational by design: it shows the reviewer what a change would do. The
decision to apply belongs to the approval in the `demo` environment (C4).
Source:
[raw/03-provocation-p2-live-change.txt](raw/03-provocation-p2-live-change.txt).

### Public log scan

1,589 lines of plan-run logs were searched. The AWS account id appears
**0** times and the operator's email **0** times. Source:
[raw/04-public-log-scan.txt](raw/04-public-log-scan.txt).

### Required check

The ruleset is active and requires `python`, `terraform`, `security`,
`hygiene` and `plan`. Source:
[raw/05-ruleset-required-checks.txt](raw/05-ruleset-required-checks.txt).

### Duration and cost

- **Duration:** the `plan` job takes about 25–32 s, including `terraform init`.
  It runs in parallel with the four static checks.
- **Cost: $0.** The runners are free for public repositories, and plan only
  reads.

## Findings during the execution

| Found | Outcome |
|---|---|
| The fleet client's key and CSR had been lost with the laptop reinstall | **Regenerated** with the runbook in `modules/iot/README.md`. The key is backed up off the laptop, and the CSR now also lives in a GitHub variable |
| `gh pr merge` right after a push was refused: "the base branch policy prohibits the merge" | **Correct behaviour:** the ruleset requires the checks of the *latest* commit. The merge waited for them; `--admin` was never used |
| Terraform's coloured output made the failure log hard to read and search | **Fixed:** `init` and `plan` run with `-no-color` |
| ADR file names did not match the links in several documents, and one ADR had no `.md` extension | **Fixed**, and a link check over every `docs/adr/` link now passes |

## What was redacted, and why

The account id, the GitHub owner login, the local user and the host name
were replaced with placeholders. Terraform's colour codes were removed. No
plan, plan JSON, state or input file is stored here.

## Files

| File | Contents |
|---|---|
| `raw/01-green-plan.txt` | the C3 pull request's plan run: job result, duration and summary |
| `raw/02-provocation-p1-invalid-value.txt` | P1: the checks of the pull request and the plan error |
| `raw/03-provocation-p2-live-change.txt` | P2: the checks of the pull request and the summary with the replace warning |
| `raw/04-public-log-scan.txt` | log lines searched and hits for the account id and email |
| `raw/05-ruleset-required-checks.txt` | the ruleset's enforcement and its required checks |
| `raw/06-local-vs-ci.txt` | the local plan's summary next to the CI plan's |
