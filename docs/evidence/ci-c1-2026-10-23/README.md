# CI quality gate — evidence (C1, 2026-10-23)

Proof that the CI quality gate described in [docs/ci-cd.md](../../ci-cd.md)
does what it claims: it passes clean code, and it **blocks the merge** of every
kind of change it is meant to stop.

**Repository and toolchain at the time of the run:** [raw/context.txt](raw/context.txt).

---

## Method

1. **Local gate first.** With the pinned toolchain verified by `make tools`,
   `make check` passed on the developer machine before anything was pushed.
2. **First green run.** The pull request that introduced the gate had to pass
   all four required checks.
3. **No leaks in public logs.** The full log of that run was downloaded and
   searched for the AWS account id and the operator's email address. The values
   were loaded into shell variables and never printed.
4. **Ruleset.** The repository ruleset was created from
   [docs/github/ruleset-protected-branches.json](../../github/ruleset-protected-branches.json).
   A direct push to `develop` was then attempted to show that it is rejected.
5. **Provoked failures.** For every gate, a pull request was built to fail on
   purpose. Each one had to:
   - go red on the expected check;
   - leave the other checks green, unless the provocation touches two of them;
   - be **blocked** by the ruleset (`mergeStateStatus = BLOCKED`);
   - show the expected message in the failed job's log.

   Every provocation was closed without merging and its branch deleted.

## Results

### Green run

| Check | Result | Duration |
|---|---|---|
| `python` | success | 49 s |
| `terraform` | success | 36 s |
| `security` | success | 9 s |
| `hygiene` | success | 5 s |

The jobs run in parallel: ~49 s wall clock. Standard runners cost $0 for a
public repository. Source: [raw/green-run-durations.tsv](raw/green-run-durations.tsv).

### Public log scan

1,261 log lines searched: **0** occurrences of the AWS account id, **0** of the
operator's email address. Source: [raw/public-log-scan.txt](raw/public-log-scan.txt).

### Ruleset

- `protected-branches`, **active**, applies to `develop` and `main`, with the
  rules `deletion`, `non_fast_forward`, `pull_request` and
  `required_status_checks`. Sources: [raw/ruleset-created.tsv](raw/ruleset-created.tsv),
  [raw/ruleset-rules.txt](raw/ruleset-rules.txt).
- A direct push to `develop` was rejected:
  `GH013: Repository rule violations … push declined due to repository rule violations`.
  Source: [raw/direct-push-rejected.txt](raw/direct-push-rejected.txt).

### Provoked failures: 15 of 15 blocked

| # | Provocation | Red check | Merge | Expected message |
|---|---|---|---|---|
| 1 | `tf-fmt`: badly formatted `.tf` | `terraform` | BLOCKED | `main.tf` |
| 2 | `tf-validate`: output that does not exist | `terraform` | BLOCKED | `Unsupported attribute` |
| 3 | `tf-lint`: variable without description | `terraform` | BLOCKED | `terraform_documented_variables` |
| 4 | `tf-lock`: provider missing from the lock file | `terraform` | BLOCKED | `hashicorp/random` |
| 5 | `tf-pin`: Terraform pin removed | `terraform` | BLOCKED | `must be pinned to an exact` |
| 6 | `trivy-finding`: SSH open to 0.0.0.0/0 | `security` | BLOCKED | `AWS-0107` |
| 7 | `trivy-parse`: unparseable `.tf` | `security`, `terraform` | BLOCKED | `trivy-gate: Trivy could not parse` |
| 8 | `secret-history`: fake key added, then deleted | `security` | BLOCKED | `gitleaks: generic-api-key` |
| 9 | `py-ruff`: unused import | `python` | BLOCKED | `F401` |
| 10 | `py-mypy`: wrong return type | `python` | BLOCKED | `Incompatible return value` |
| 11 | `py-test`: failing test | `python` | BLOCKED | `test_provocation_fails` |
| 12 | `py-coverage`: floor raised to 100 % (actual 99.28 %) | `python` | BLOCKED | `Required test coverage of 100%` |
| 13 | `guard-name`: `.tfvars` forced with `git add -f` | `hygiene` | BLOCKED | `zz-provocation.tfvars` |
| 14 | `guard-content`: real-looking email in a template | `hygiene` | BLOCKED | `outside the example domains (value not shown)` |
| 15 | `actionlint`: expression pointing to a missing step | `hygiene` | BLOCKED | `property "pin" is not defined` |

Provocation 14 also checked that the guard does not publish what it protects:
the planted address appears **0 times** in the public log
([raw/guard-content-leakcheck.txt](raw/guard-content-leakcheck.txt)).

Summary table: [raw/provocations.tsv](raw/provocations.tsv). Each provocation,
with its checks and the matching log lines, is in [raw/provocations/](raw/provocations/).

## What did not go as planned

Reported as it happened, because each one changed the gate:

- **Provocation 8, first attempt.** The merge was blocked, but the log said
  only `leaks found: 1`, with no rule, file or commit. The gate was fixed to
  print those fields without the commit author's data
  (`scripts/tooling/gitleaks-gate.sh`), and the provocation was repeated.
- **Provocation 15, first design.** A misspelled input of a SHA-pinned action
  passed actionlint and could have been merged. actionlint validates action
  inputs by tag, so pinning by SHA disables that check. The limitation is
  recorded in ADR-0022, and the provocation was redesigned to test what
  actionlint does catch here (expressions).
- **Cross-branch effect.** While the branch of provocation 8 still existed, the
  `security` check of an unrelated pull request also failed, because the
  history scan reads every fetched branch. It was confirmed and recorded in
  ADR-0022 as intended behaviour for a public repository.

## What was redacted

GitHub owner, local user and host names were replaced with `<OWNER>`, `<USER>`
and `<HOST>`. The run logs themselves are not published; only the lines that
prove each result are. No secret, account id or email address is stored in
this folder. The fake key and the fake address used in provocations 8 and 14
were never valid.

## Files

```text
ci-c1-2026-10-23/
├── README.md                     this report
└── raw/
    ├── context.txt               repository, merge commits, runner, toolchain
    ├── green-run-durations.tsv   the four checks of the first green run
    ├── public-log-scan.txt       account id / email occurrences in that run's log
    ├── ruleset-created.tsv       the ruleset as created
    ├── ruleset-rules.txt         the rules active on develop and main
    ├── direct-push-rejected.txt  the rejected direct push
    ├── provocations.tsv          one row per provocation
    ├── provocations/<id>.txt     checks and matching log lines, per provocation
    └── guard-content-leakcheck.txt
```
