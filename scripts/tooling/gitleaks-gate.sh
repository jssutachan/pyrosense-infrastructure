#!/usr/bin/env bash
# gitleaks gate over the full git history.
#
# Default gitleaks output only says "leaks found: N"; --verbose would add the
# commit author's name and email to a public CI log. Instead, the findings are
# written to a JSON report and only rule, file, line and commit are printed,
# which is what an operator needs to locate, purge and rotate. The secret
# itself is redacted in the report too.
#
# Usage: scripts/tooling/gitleaks-gate.sh

set -euo pipefail

report="$(mktemp)"
trap 'rm -f "$report"' EXIT

set +e
gitleaks git --redact --report-format json --report-path "$report" .
scan_status=$?
set -e

if [[ "$scan_status" -ne 0 ]]; then
  jq -r '.[] | "gitleaks: \(.RuleID) in \(.File):\(.StartLine) (commit \(.Commit[0:12]))"' "$report" >&2
fi
exit "$scan_status"
