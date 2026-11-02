#!/usr/bin/env bash
# Prints the exact version pinned for a tool in .tool-versions, or fails.
#
# Workflows that install a tool through an action call this instead of
# reading .tool-versions inline. hashicorp/setup-terraform resolves an empty
# or malformed version to the latest release, so a missing or loose pin must
# fail here rather than install a different Terraform and stay green
# (ADR-0022, docs/ci-cd.md section 2.4).
#
#   version="$(scripts/tooling/tool-version.sh terraform)"
set -euo pipefail

tool="${1:?usage: tool-version.sh <tool>}"
version="$(awk -v t="$tool" '$1 == t { print $2 }' .tool-versions)"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error file=.tool-versions::${tool} must be pinned to an exact X.Y.Z version (found: '${version}')" >&2
  exit 1
fi
printf '%s\n' "$version"
