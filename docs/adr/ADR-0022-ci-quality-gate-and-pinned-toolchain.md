# ADR-0022: CI quality gate and pinned toolchain

- **Status:** Proposed
- **Date:** 2026-10-21
- **Stage:** CI/CD, sub-stage C1 (static CI)

## Context

Before this decision the repository had three gates that disagreed:

- `ci.yml` ran only the Python half (ruff, mypy, pytest with coverage), behind
  a `paths:` filter that left out `scripts/`, so a change confined to
  `scripts/` merged with no check at all.
- `make check` ran the full gate locally but did not measure coverage, so
  `fail_under = 90` was never enforced there.
- pre-commit pinned its own copies of ruff (0.16.4) and gitleaks (8.30.0)
  while the virtualenv and PATH carried others (0.16.8, 8.30.1), and
  `requirements-dev.txt` used `~=` ranges, so CI could resolve a third ruff.

Two scanner behaviours made "green" unreliable:

- Trivy downloads its checks bundle from a floating tag on every run, so the
  rules change without any change in the repository.
- Trivy logs `Error parsing file` and still exits 0, even with
  `--exit-code 1` (reproduced with 0.75.0 on 2026-10-21). By default it also
  parses saved plans (`terraformplan-json`, `terraformplan-snapshot`), which
  is how a stray `tfplan` broke a run (debt #8).

The repository is public. Workflow logs are readable by any signed-in GitHub
user, and two supply-chain incidents hit tools of this exact kind:
`tj-actions/changed-files` (CVE-2025-30066, tags moved to a malicious commit)
and Trivy itself (GHSA-69fq-xp46-6x23, March 2026: malicious v0.69.4 binary,
hijacked `setup-trivy` and `trivy-action` tags).

## Decision

**D1. One gate, defined in the Makefile.** CI jobs call `make` targets;
pre-commit calls `make py-fix` for Python. No gate logic is duplicated in YAML.
`make check` now also runs `guard` and `ci-lint`, and `py-test` enforces the
coverage floor.

**D2. Four required checks, no path filters.** Jobs `python`, `terraform`,
`security` and `hygiene` run on every pull request and push to `develop` and
`main`. A repository ruleset (`docs/github/ruleset-protected-branches.json`)
makes all four required, requires a pull request, blocks force pushes and
branch deletion, and has an empty bypass list.

**D3. One source of truth per kind of version.**
- Binaries and Python: `.tool-versions` (asdf format, read natively by
  `actions/setup-python` and by asdf/mise locally).
- Python packages: `requirements-dev.txt` with exact `==` pins.
- Providers: the committed `.terraform.lock.hcl`, verified with
  `init -lockfile=readonly`.
- pre-commit hooks for tools no longer pin a second copy: they run the
  installed binary, which `make tools` checks against the pins.

**D4. Binaries are verified against hashes committed here.**
`scripts/tooling/install-tool.sh` downloads TFLint, Trivy, gitleaks and
actionlint and checks each archive against `scripts/tooling/checksums.txt`.
Terraform is installed by `hashicorp/setup-terraform`. Only first-party
actions are used (`actions/*`, `hashicorp/*`), each pinned to a full commit
SHA with the version in a comment. `setup-trivy` and `setup-tflint` are not
used.

**D5. Trivy is deterministic.** `trivy.yaml` sets `rego.skip-check-update`
(use the checks embedded in the pinned binary) and limits
`misconfiguration.scanners` to `terraform`. `make sec-config` removes any
cached checks bundle first, so a bundle downloaded by an earlier unpinned run
cannot take precedence locally. `scripts/tooling/trivy-gate.sh` fails the gate
when Trivy reports a parse error. Rules move forward only when the pinned
binary is bumped.

**D6. Secrets are scanned across history.** `make secrets` runs
`gitleaks git` over every commit; the CI job checks out full history. The
pre-commit hook keeps scanning staged changes.

**D7. Release cooldown.** A new tool or action version is adopted only after
it has been public for at least 14 days, unless it fixes a vulnerability that
affects this repository. Trivy is pinned at 0.75.0 (2026-10-01) rather than
0.76.0 (2026-10-14) or 0.76.1 (2026-10-21).

## Rationale

- A gate defined in one place cannot drift between laptop, hook and CI
  (Fowler: one command builds and verifies from a clean checkout).
- A required check that does not run is either a merge blocked forever or a
  merge unchecked; neither is acceptable, and the minutes are free for a
  public repository on standard runners.
- Hashes committed in the repository survive a compromised release, because
  the attacker controls the release page, not this repository.
- Determinism over freshness for the scanner: the same commit must produce
  the same verdict, and rule updates must arrive as a reviewable diff.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Keep `paths:` filters to save minutes | Minutes are free here; filters made `scripts/` unchecked and conflict with required checks |
| Workflow that reports `success` when filtered out | A fabricated green: the check claims a verification that never ran |
| `aquasecurity/setup-trivy` / `trivy-action` | Compromised in March 2026; also clones an install script at runtime. Own installer plus committed hash has a smaller trust surface |
| `terraform-linters/setup-tflint` with its `checksums` input | Viable; rejected only to keep one installer and one checksum file for every binary |
| Floating Trivy checks bundle | Fresh rules, but a verdict that changes with no change in the repository |
| `--skip-check-update` without cleaning the cache | Locally, an old cached bundle would silently win over the embedded checks |
| Full lock of transitive Python dependencies (uv / pip-compile with hashes) | Right for production, deferred: larger change to the local workflow; recorded in production readiness |
| Dependabot or Renovate in this sub-stage | Belongs to C5; until then bumps are manual and reviewed |

## Consequences

- Positive: a red check means the code changed or a pin changed, nothing else.
  Every gate is required and visible in the public ruleset.
- Negative: bumping a binary takes two edits (version and hash) and a manual
  check of the release. The embedded Trivy checks age between bumps. Python is
  pinned to a patch release (3.12.13) that also has to be bumped by hand.
- Workflow change: with the ruleset active, `develop` and `main` accept
  changes only through pull requests. A local `git merge --no-ff` followed by
  `git push` is rejected; merges go through a PR with "Create a merge commit".
- The ADR that places the pipeline identity (originally announced as
  ADR-0022 in the CI/CD contract) becomes ADR-0023.
- Limitation: actionlint cannot validate the inputs of actions pinned by a full
  commit SHA, because its action metadata is indexed by tag. A misspelled
  `with:` key passes the gate, and GitHub only warns at runtime ("Unexpected
  input"). Inputs of pinned actions are reviewed by hand on every workflow
  diff. Reproduced with actionlint 1.7.12 on 2026-10-23.
- `gitleaks git` scans every branch present in the clone, and the `security`
  job checks out all branches. A leak on any remote branch therefore fails the
  `security` check of every pull request until that branch is deleted or
  rewritten. Accepted: in a public repository, a secret on any branch is
  already exposed, so stopping every merge until it is purged is the intended
  response.

## Revisit if

- A required check stays red for a reason outside the repository (a
  registry outage, an action removed) more than once a month.
- C5 adds an update bot that can bump `.tool-versions` and
  `checksums.txt` together; D3/D4 move to that bot.
- A Trivy rule relevant to this code ships in a release newer than the pin
  and the 14-day cooldown blocks a needed fix.
- The repository becomes private (minutes, rulesets and environments change
  with the plan).
- A linter in the gate can resolve SHA-pinned actions to their `action.yml`;
  the input check is then restored.
