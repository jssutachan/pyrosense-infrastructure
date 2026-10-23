#!/usr/bin/env bash
# Repository guard: fail if git tracks something that must never be published.
#
# 1. Forbidden files, by name: plans and state carry sensitive values in
#    cleartext, tfvars and backend.hcl carry PII and the account id, and CSRs
#    and keys pin a device identity (ADR-0017). Catches `git add -f` and files
#    tracked before they were ignored.
# 2. Committed templates (*.example), by content: they are copied to the real
#    file and edited, so a real value typed into the template instead of the
#    copy would pass the name check. Templates may only carry addresses under
#    the reserved example domains (RFC 2606) and no 12-digit AWS account id.
#
# Findings print file:line only. CI logs are public: the guard must not
# publish the value it is protecting.

set -euo pipefail

status=0

forbidden=(
  ':(glob)**/tfplan*' ':(glob)**/*.tfplan'
  ':(glob)**/*.tfstate' ':(glob)**/*.tfstate.*'
  ':(glob)**/*.tfvars' ':(glob)**/*.tfvars.json'
  ':(glob)**/backend.hcl'
  ':(glob)**/*.csr' ':(glob)**/*.pem' ':(glob)**/*.key'
)
tracked="$(git ls-files -- "${forbidden[@]}")"
if [[ -n "$tracked" ]]; then
  echo "guard: tracked files that must never be committed:"
  while IFS= read -r file; do echo "  $file"; done <<< "$tracked"
  status=1
fi

email='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
reserved='@example\.(com|net|org)$'
account_id='(^|[^0-9])[0-9]{12}([^0-9]|$)'

while IFS= read -r template; do
  [[ -f "$template" ]] || continue
  real_emails="$(grep -noE "$email" "$template" | grep -vE "$reserved" | cut -d: -f1 || true)"
  for line in $real_emails; do
    echo "guard: $template:$line has an address outside the example domains (value not shown)"
    status=1
  done
  ids="$(grep -nE "$account_id" "$template" | cut -d: -f1 || true)"
  for line in $ids; do
    echo "guard: $template:$line has what looks like an AWS account id (value not shown)"
    status=1
  done
done < <(git ls-files -- ':(glob)**/*.example')

if [[ "$status" -eq 0 ]]; then
  echo "guard: no forbidden files tracked; templates carry placeholders only"
fi
exit "$status"
