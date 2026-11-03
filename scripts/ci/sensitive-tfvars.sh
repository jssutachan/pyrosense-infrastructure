#!/usr/bin/env bash
# Builds layer 2 of the plan inputs in CI (ADR-0024); layer 1 is the
# committed demo.tfvars.example. One definition for every job that plans demo
# (plan.yml and deploy.yml), so a pull request and a delivery plan the same
# inputs.
#
# Reads from the environment:
#   OPS_RECIPIENTS         secret DEMO_OPS_RECIPIENTS, JSON {"<label>": "<email>"}
#   FIRE_ALERT_RECIPIENTS  secret DEMO_FIRE_ALERT_RECIPIENTS, same shape
#   FLEET_CLIENT_CSR       variable DEMO_IOT_FLEET_CLIENT_CSR, PEM text. Public
#                          material (a public key and a name); it lives outside
#                          the repository only because the guard refuses
#                          tracked *.csr files.
# Writes <dir>/sensitive.tfvars.json and <dir>/fleet-client.csr, owner-only.
# Never prints a value.
#
# Usage: scripts/ci/sensitive-tfvars.sh "$RUNNER_TEMP"
set -euo pipefail

dir="${1:?usage: sensitive-tfvars.sh <output dir>}"

for name in OPS_RECIPIENTS FIRE_ALERT_RECIPIENTS FLEET_CLIENT_CSR; do
  [[ -n "${!name:-}" ]] || {
    echo "::error::${name} is empty: see docs/ci-cd.md section 9.6"
    exit 1
  }
done

umask 077
printf '%s\n' "$FLEET_CLIENT_CSR" >"$dir/fleet-client.csr"

# --argjson rejects malformed JSON without echoing it.
jq -n \
  --argjson ops "$OPS_RECIPIENTS" \
  --argjson fire "$FIRE_ALERT_RECIPIENTS" \
  --arg csr "$dir/fleet-client.csr" \
  '{ops_recipients: $ops, fire_alert_recipients: $fire, iot_fleet_client_csr_path: $csr}' \
  >"$dir/sensitive.tfvars.json"

echo "sensitive input layer written (values not shown)"
