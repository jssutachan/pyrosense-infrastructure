#!/usr/bin/env bash
# Compare the tools on PATH with the versions pinned in .tool-versions.
# Fails if any tool is missing or differs: a local gate that runs a different
# scanner version than CI is a different gate.
#
# Usage: scripts/tooling/check-tool-versions.sh [python-bin-prefix]
#   python-bin-prefix: where python lives, e.g. ".venv/bin/" (default: PATH)

set -euo pipefail

py_prefix="${1:-}"
root="$(git rev-parse --show-toplevel)"

installed() {
  case "$1" in
    python)     "${py_prefix}python" --version 2>&1 | awk '{ print $2 }' ;;
    terraform)  terraform version | awk 'NR == 1 { sub(/^v/, "", $2); print $2 }' ;;
    tflint)     tflint --version | awk 'NR == 1 { print $3 }' ;;
    trivy)      trivy --version 2>/dev/null | awk '/^Version:/ { print $2 }' ;;
    gitleaks)   gitleaks version ;;
    actionlint) actionlint --version | awk 'NR == 1 { print $1 }' ;;
  esac
}

status=0
while read -r tool want _; do
  [[ -z "$tool" || "$tool" == \#* ]] && continue
  have="$(installed "$tool" 2>/dev/null || true)"
  if [[ "$have" == "$want" ]]; then
    printf '  %-11s %-9s ok\n' "$tool" "$want"
  else
    printf '  %-11s %-9s MISMATCH (installed: %s)\n' "$tool" "$want" "${have:-not found}"
    status=1
  fi
done < "$root/.tool-versions"

if [[ "$status" -ne 0 ]]; then
  echo "pinned versions live in .tool-versions; scripts/tooling/install-tool.sh installs them" >&2
fi
exit "$status"
