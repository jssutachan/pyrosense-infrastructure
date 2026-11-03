#!/usr/bin/env bash
# Markdown summary of a saved Terraform plan that is safe for a public log.
#
# The JSON form of a plan carries every attribute value in clear text,
# sensitive ones included: they are only flagged in before_sensitive /
# after_sensitive. So this script reads exactly two fields per resource,
# its address and its actions, and nothing else (ADR-0024).
#
#   terraform show -json tfplan > plan.json
#   scripts/ci/plan-summary.sh plan.json [environment]
set -euo pipefail

json="${1:?usage: plan-summary.sh <plan.json> [environment]}"
env_name="${2:-demo}"

jq -r --arg env "$env_name" '
  # Names of the top-level attributes an in-place update changes. Values are
  # compared in memory and never printed; unknown-after-apply counts as changed.
  def changed_attrs:
    (.change.before // {}) as $b | (.change.after // {}) as $a | (.change.after_unknown // {}) as $u
    | [ (($a | keys) + ($b | keys) + ($u | keys)) | unique[]
        | select($a[.] != $b[.] or (($u[.] // false) | tostring | test("true"))) ];
  [ .resource_changes[]? | {address, a: (.change.actions | join(",")),
      attrs: (if (.change.actions | join(",")) == "update" then changed_attrs else [] end)} ] as $all
  | ($all | map(select(.a == "create")  | .address)) as $create
  | ($all | map(select(.a == "update")  | .address)) as $update
  | ($all | map(select(.a == "update")  | "- `\(.address)` (attributes: `\(.attrs | join("`, `"))`)")) as $update_lines
  | ($all | map(select(.a == "delete")  | .address)) as $delete
  | ($all | map(select(.a == "delete,create" or .a == "create,delete") | .address)) as $replace
  | ($all | map(select(.a == "no-op")   | .address)) as $unchanged
  | def bullets: map("- `\(.)`") | join("\n");
    "### Terraform plan: `\($env)`",
    "",
    "| Create | Update | Replace | Destroy | Unchanged |",
    "|---:|---:|---:|---:|---:|",
    "| \($create|length) | \($update|length) | \($replace|length) | \($delete|length) | \($unchanged|length) |",
    "",
    ( if (($replace|length) + ($delete|length)) > 0
      then "> [!WARNING]\n> This change destroys or replaces existing resources:\n"
           + ((($replace|map(. + " (replace)")) + $delete) | map("> - `\(.)`") | join("\n"))
      else "No existing resource is destroyed or replaced." end ),
    "",
    ( if ($update|length) > 0 then "**Updated in place**\n\n" + ($update_lines|join("\n")) + "\n" else empty end ),
    ( if ($create|length) > 0
      then "<details><summary>Created (\($create|length))</summary>\n\n" + ($create|bullets) + "\n\n</details>\n"
      else empty end ),
    ( if ($unchanged|length) > 0
      then "<details><summary>Unchanged, already deployed (\($unchanged|length))</summary>\n\n" + ($unchanged|bullets) + "\n\n</details>\n"
      else empty end ),
    "Addresses, actions and the names of changed attributes only: attribute values are never printed. `demo` is ephemeral (ADR-0002), so while it is destroyed every resource appears under **Create**; the always-on budget lives in `bootstrap/finops`."
' "$json"
