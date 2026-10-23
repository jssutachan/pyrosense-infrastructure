#!/usr/bin/env bash
# Install a pinned release binary (linux amd64) after checking its SHA-256
# against scripts/tooling/checksums.txt.
#
# The expected hash lives in this repository, not in the release: a release
# whose assets and checksums file were both replaced (tj-actions, March 2025;
# Trivy v0.69.4, March 2026) still fails here, because the attacker cannot
# change a hash we committed.
#
# Usage: scripts/tooling/install-tool.sh <tool> [install-dir]
#   tools: tflint | trivy | gitleaks | actionlint
#   install-dir defaults to ~/.local/bin. In GitHub Actions the directory is
#   also appended to GITHUB_PATH so later steps find the binary.

set -euo pipefail

tool="${1:?usage: install-tool.sh <tool> [install-dir]}"
dest="${2:-$HOME/.local/bin}"

if [[ "$(uname -sm)" != "Linux x86_64" ]]; then
  echo "install-tool: only linux amd64 assets are pinned in checksums.txt" >&2
  exit 1
fi

root="$(git rev-parse --show-toplevel)"
version="$(awk -v t="$tool" '$1 == t { print $2 }' "$root/.tool-versions")"
if [[ -z "$version" ]]; then
  echo "install-tool: '$tool' is not pinned in .tool-versions" >&2
  exit 1
fi

case "$tool" in
  tflint)     url="https://github.com/terraform-linters/tflint/releases/download/v${version}/tflint_linux_amd64.zip" ;;
  trivy)      url="https://github.com/aquasecurity/trivy/releases/download/v${version}/trivy_${version}_Linux-64bit.tar.gz" ;;
  gitleaks)   url="https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_linux_x64.tar.gz" ;;
  actionlint) url="https://github.com/rhysd/actionlint/releases/download/v${version}/actionlint_${version}_linux_amd64.tar.gz" ;;
  *)
    echo "install-tool: unsupported tool '$tool'" >&2
    exit 1
    ;;
esac

# A version bump without a matching hash must fail, never install unverified.
expected="$(awk -v t="$tool" -v v="$version" '$1 == t && $2 == v { print $3 }' \
  "$root/scripts/tooling/checksums.txt")"
if [[ -z "$expected" ]]; then
  echo "install-tool: no checksum for $tool $version in scripts/tooling/checksums.txt" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
asset="$tmp/${url##*/}"

curl --fail --silent --show-error --location --retry 3 --output "$asset" "$url"
echo "${expected}  ${asset}" | sha256sum --check --quiet --strict -

case "$asset" in
  *.zip)    unzip -q -o "$asset" "$tool" -d "$tmp" ;;
  *.tar.gz) tar -xzf "$asset" -C "$tmp" "$tool" ;;
esac

mkdir -p "$dest"
install -m 0755 "$tmp/$tool" "$dest/$tool"
echo "install-tool: $tool $version -> $dest/$tool (sha256 verified)"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$dest" >> "$GITHUB_PATH"
fi
