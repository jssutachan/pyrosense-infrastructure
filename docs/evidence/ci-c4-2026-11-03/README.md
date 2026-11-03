# Evidence: C4, manual delivery to `demo` (2026-11-03)

What this proves: `demo` was deployed, tested end to end and destroyed **from
GitHub Actions**, behind the maintainer's approval, applying only the plan the
reviewer read. The design is ADR-0025; the explanation is
[docs/ci-cd.md, section 10](../../ci-cd.md#10-manual-delivery-to-demo-c4).

## Results

| Test | Result |
|---|---|
| Trust pinned to `deploy.yml` on `main` | the old probe job, approved in `demo`, was refused by AWS although its `sub`, `ref` and `environment` matched |
| Budget moved out of the main state | imported into `bootstrap/finops`; nothing created or destroyed |
| First deliveries | 4 missing permissions found: 2 loud (`AccessDenied`), 2 silent (caught by `plan_guard` and by the reviewer); fixed without wildcards |
| Final apply | plan identical to the operator's · fingerprint matched · converged · 13 of 13 smoke checks · 3 of 3 escalation attempts refused |
| End to end (operator, certificate issued by the pipeline) | 7 messages · 0 errors · 8 hot items · 7 archived objects · DLQ empty · fire alert received |
| Destroy | 50 destroyed · main state empty · budget untouched |
| Public logs | 0 account ids, 0 emails in 33 lines across 51 runs |

## Raw files

All files are redacted: account id → `<ACCOUNT_ID>`, owner → `<OWNER>`, owner
and repository ids → `<OWNER_ID>`, `<REPO_ID>`, emails → `<EMAIL>`, local user
and host → `<USER>`, `<HOST>`, IoT endpoint → `<IOT_ENDPOINT>`.

| File | Contents |
|---|---|
| [`01-identity-changes.txt`](raw/01-identity-changes.txt) | the four operator applies of `bootstrap/ci-identity`: the `job_workflow_ref` pin and the three fixes |
| [`02-provocation-old-probe.txt`](raw/02-provocation-old-probe.txt) | the claims of the old probe job and the refusal |
| [`03-runs-and-reviews.txt`](raw/03-runs-and-reviews.txt) | every `deploy.yml` run: jobs, conclusions and the reviewer's decision with its comment |
| [`04-apply-1-access-denied.txt`](raw/04-apply-1-access-denied.txt) | the two `AccessDenied` of the first apply |
| [`05-apply-2-guard-refused.txt`](raw/05-apply-2-guard-refused.txt) | `plan_guard` refusing the bucket replacements |
| [`06-cloudtrail-and-simulator.txt`](raw/06-cloudtrail-and-simulator.txt) | the plan role's `Decrypt` refusals and successes, and the IAM simulator checks of the new scopes |
| [`07-apply-ok.txt`](raw/07-apply-ok.txt) | the successful delivery: claims, escalation checks, fingerprint, apply, convergence, smoke |
| [`08-end-to-end.txt`](raw/08-end-to-end.txt) | the operator's publish and the counts on the other side |
| [`09-destroy.txt`](raw/09-destroy.txt) | drift report, destroy, and independent checks afterwards |
| [`10-public-log-scan.txt`](raw/10-public-log-scan.txt) | account id and email occurrences in the public logs |
