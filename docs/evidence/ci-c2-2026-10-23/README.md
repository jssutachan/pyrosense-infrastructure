# Pipeline identity: evidence (C2, 2026-10-23)

This is the proof that the pipeline identity described in
[docs/ci-cd.md, section 8](../../ci-cd.md#8-pipeline-identity-c2) does what it
claims. The pipeline gets AWS credentials with **no stored key**. Each role can
be assumed only from the context it was built for. Every forbidden action,
including the privilege-escalation path, is **refused by AWS itself**.

Decision record: [ADR-0023](../../adr/0023-pipeline-identity-oidc-and-workload-boundary.md).

---

## Method

1. **Measure before granting.** CloudTrail Event History for 2026-10-14..20
   (three deploy/destroy cycles) gave the 116 distinct API calls Terraform
   makes. They were translated to IAM actions and completed with the
   permissions that never appear as events (ADR-0023, Context).
2. **Static gate.** `make check` passed with the new stack included in
   `validate` (three Terraform roots) and in the Trivy scan, before anything was
   applied.
3. **Operator apply.** `bootstrap/ci-identity` was applied with the operator's
   credentials from a reviewed saved plan: `17 to add, 0 to change, 0 to
   destroy`.
4. **GitHub configuration.** The `demo` environment was created *before* the
   first run that names it. It has the maintainer as required reviewer, `main`
   as the only deployment branch, and no administrator bypass. Role ARNs are
   secrets.
5. **Probe, two contexts.** The OIDC probe workflow
   ([.github/workflows/oidc-probe.yml](../../../.github/workflows/oidc-probe.yml))
   obtained real credentials in each context and created nothing:
   - in a pull request, it used the plan role;
   - in a manual run approved for `demo`, it used the apply role.

   Each job printed the token claims AWS evaluated. It then asserted that the
   forbidden actions failed **with an authorization error**. Any other failure,
   or a success, fails the job.
6. **AWS's own record.** CloudTrail was queried for every
   `AssumeRoleWithWebIdentity` of the day, accepted and refused.
7. **Public logs.** The logs of every successful probe run were downloaded and
   searched for the account id and the operator's email.

## Results

### Who can obtain credentials

| Context | Role requested | Expected | Observed |
|---|---|---|---|
| Pull request, started by the maintainer | `pyrosense-ci-plan` | allowed | ✅ allowed |
| Pull request | `pyrosense-ci-apply-demo` | refused by the trust policy | ✅ `AccessDenied` |
| Manual run in the `demo` environment, after approval | `pyrosense-ci-apply-demo` | allowed | ✅ allowed |

GitHub held the `demo` job until the maintainer approved it. Before that
approval the job had no runner, no token and no environment secret. The
approval is recorded in [raw/03-probe-apply-role.txt](raw/03-probe-apply-role.txt).

The `sub` claims AWS received use GitHub's **immutable** format, in which the
owner and repository carry numeric ids:

```text
repo:<OWNER>@<OWNER_ID>/pyrosense-infrastructure@<REPO_ID>:pull_request
repo:<OWNER>@<OWNER_ID>/pyrosense-infrastructure@<REPO_ID>:environment:demo
```

GitHub documents this format only with a branch context (`ref:`). These runs
confirm it for pull requests and environments too, which the trust policies
depend on.

### What each role cannot do

| Job | Attempt | Expected | Observed |
|---|---|---|---|
| `plan-role` | create an SQS queue | refused | ✅ refused by AWS |
| `plan-role` | assume the apply role from a pull request | refused | ✅ refused by AWS |
| `apply-role` | **create an IAM role without the workload boundary**: the escalation path | refused | ✅ refused by AWS |
| `apply-role` | create a queue of another environment (`pyrosense-prod-*`) | refused | ✅ refused by AWS |
| `apply-role` | tag the pipeline's own role | refused | ✅ refused by AWS |

Both jobs could also find the workload boundary by name, the same lookup the
main configuration's plan makes. Sources:
[raw/02-probe-plan-role.txt](raw/02-probe-plan-role.txt) and
[raw/03-probe-apply-role.txt](raw/03-probe-apply-role.txt).

### The same events, seen from AWS

CloudTrail recorded **5** `AssumeRoleWithWebIdentity` events. There is one
for every attempt above and nothing else:
- **3 accepted:** the plan role from pull requests #22 and #23, and the apply
  role from the approved `demo` run.
- **2 refused:** the apply role requested from those two pull requests.

Source:
[raw/04-cloudtrail-assume-role-with-web-identity.tsv](raw/04-cloudtrail-assume-role-with-web-identity.tsv).

For the refused requests, CloudTrail records no role and no session name
(`?` and `-` in the file): the event carries no request parameters. Each
refusal is matched to the probe step that requested the apply role by its
timing: it comes 6 seconds after the plan-role session of the same run, the
order of the job's steps. The job log names the role it requested
([raw/02-probe-plan-role.txt](raw/02-probe-plan-role.txt)).

### The boundary reaches every workload role

A plan of the main configuration, made with the operator's credentials and a
throwaway CSR, shows that the three IAM roles it creates all carry
`pyrosense-workload-boundary`:
- `module.iot.aws_iam_role.forward`;
- `module.iot.aws_iam_role.errors`;
- `module.ingest.aws_iam_role.ingest`.

A role without it could not be created by the pipeline at all (above).
Source: [raw/06-boundary-wiring.txt](raw/06-boundary-wiring.txt).

### The identity stack equals its code

After the runs, a plan of `bootstrap/ci-identity` reports no changes
(`exit=0`). The state lists the 17 resources. Source:
[raw/01-identity-stack.txt](raw/01-identity-stack.txt).

### Public log scan

795 log lines from every successful probe run were searched. The AWS account id
appears **0** times and the operator's email **0** times. The role ARNs are
secrets and the action masks the account id. Source:
[raw/05-public-log-scan.txt](raw/05-public-log-scan.txt).

### Cost

$0:
- IAM roles, policies and identity providers have no charge;
- the probe creates nothing;
- standard GitHub-hosted runners are free for public repositories.

## Findings during the execution

| Found | Why it mattered | Outcome |
|---|---|---|
| `backend.hcl` was ignored by git only under `config/` | The new stack's `backend.hcl` holds the account id and showed up as untracked. `guard.sh` would have failed CI, but only after a push, when it is already published | **Fixed:** `.gitignore` ignores `backend.hcl` in every folder |
| A new GitHub environment allows administrator bypass by default | The maintainer is the administrator, so the approval would have been optional for the only person who deploys | **Fixed:** `can_admins_bypass: false`, kept in [docs/github/environment-demo.json](../../github/environment-demo.json) |
| Naming an environment that does not exist creates it **unprotected** | A first run before the configuration would have obtained apply credentials with no approval | **Avoided by order:** the environment was configured before the first run that names it. The order is written in the stack's README |
| The main configuration reads the IoT device CSR from a file on the operator's machine | A fresh machine, or a CI runner, cannot plan without it | **Open, for C3:** decide how the plan job receives the (public) CSR |
| The state-backend's logging suppression said CloudTrail records "S3 API calls" | True for bucket-level calls only: reads and writes of the state object are data events | **Corrected** and re-evaluated in `bootstrap/state-backend`; a production trail is listed in production readiness |

## What was redacted, and why

The account id, the GitHub owner login, the owner and repository ids, the
local user and the host name were replaced with placeholders such as
`<ACCOUNT_ID>` and `<OWNER_ID>`. The GitHub identifiers are public and none of
these values is a credential; they are removed as a data-minimization habit.
No token, credential, state or plan is stored in this folder.

## Files

| File | Contents |
|---|---|
| `raw/01-identity-stack.txt` | plan of `bootstrap/ci-identity` after the runs (no changes) and its state list |
| `raw/02-probe-plan-role.txt` | pull request run: job duration, claims, assumed role, allowed and refused checks |
| `raw/03-probe-apply-role.txt` | `demo` run: job duration, the approval, claims, assumed role, allowed and refused checks |
| `raw/04-cloudtrail-assume-role-with-web-identity.tsv` | every credential request of the day, with its result |
| `raw/05-public-log-scan.txt` | log lines searched and hits for the account id and email |
| `raw/06-boundary-wiring.txt` | IAM roles in the main configuration's plan and their boundary |
