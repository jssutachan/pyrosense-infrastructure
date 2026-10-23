#!/usr/bin/env bash
# Trivy misconfiguration gate: fail on HIGH/CRITICAL findings AND on any file
# Trivy could not parse.
#
# Trivy logs "Error parsing file" and still exits 0, even with --exit-code 1:
# a file it cannot parse is a file it did not scan, and the gate would stay
# green on code nobody checked (verified with trivy 0.75.0, 2026-10-21).
#
# Usage: scripts/tooling/trivy-gate.sh <tfvars-file>

set -euo pipefail

tfvars="${1:?usage: trivy-gate.sh <tfvars-file>}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

set +e
trivy config . --tf-vars "$tfvars" --severity HIGH,CRITICAL --exit-code 1 2>&1 | tee "$log"
scan_status="${PIPESTATUS[0]}"
set -e

if grep -q 'Error parsing' "$log"; then
  echo "trivy-gate: Trivy could not parse at least one file (see 'Error parsing' above);" \
       "the scan is incomplete, so the gate fails." >&2
  exit 1
fi

exit "$scan_status"
