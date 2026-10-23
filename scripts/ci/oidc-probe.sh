#!/usr/bin/env bash
# Helpers for .github/workflows/oidc-probe.yml (ADR-0023).
#
#   oidc-probe.sh claims
#       Print the claims of a fresh GitHub OIDC token: the values AWS compares
#       with the trust policies. The token itself is masked and never printed.
#
#   oidc-probe.sh expect-denied <what> -- <command> [args...]
#       Run a command that AWS MUST refuse. Passes only on an authorization
#       error. If AWS allows it, or it fails for another reason, the step fails.
#
#   oidc-probe.sh expect-assume-denied <role-arn>
#       Ask STS for that role with a fresh token from this job. Passes only if
#       STS refuses: proves the trust policy rejects this context.
#
# Needs `permissions: id-token: write` for the token calls. Runs only on
# GitHub-hosted runners (curl, jq and the AWS CLI are preinstalled).
set -euo pipefail

readonly AUDIENCE="sts.amazonaws.com"

die() { echo "::error::$*" >&2; exit 1; }

# Prints the raw token on stdout; callers capture it and mask it.
fetch_token() {
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]] \
    || die "no OIDC token endpoint: the job needs 'permissions: id-token: write'"
  curl -sSf \
    -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUDIENCE}" | jq -r .value
}

# A JWT is header.payload.signature, each part base64url without padding.
decode_payload() {
  local payload
  payload="$(cut -d. -f2 <<<"$1" | tr '_-' '/+')"
  while (( ${#payload} % 4 )); do payload+="="; done
  base64 -d <<<"$payload"
}

# AWS error messages name the caller's ARN, which contains the account id.
redact() { sed -E 's/[0-9]{12}/<ACCOUNT_ID>/g'; }

claims() {
  local token
  token="$(fetch_token)"
  echo "::add-mask::${token}"
  decode_payload "$token" | jq '{sub, aud, repository_id, repository_owner_id,
                                 actor_id, event_name, ref, environment}'
}

expect_denied() {
  local what="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  (( $# > 0 )) || die "expect-denied: no command given"

  local out status
  set +e
  out="$("$@" 2>&1)"
  status=$?
  set -e

  if (( status == 0 )); then
    # The output is not printed: on an unexpected success it may hold
    # credentials or resource identifiers.
    die "${what}: AWS ALLOWED it. The role is broader than designed (ADR-0023)."
  fi
  if grep -qE 'AccessDenied|UnauthorizedOperation|AuthorizationError|not authorized' <<<"$out"; then
    echo "ok: ${what} -> refused by AWS"
    grep -oE '\(([A-Za-z]*AccessDenied[A-Za-z]*|[A-Za-z]*Unauthorized[A-Za-z]*)\)' <<<"$out" | head -n 1 || true
    return 0
  fi
  echo "${what}: failed, but not with an authorization error:" >&2
  redact <<<"$out" >&2
  exit 1
}

expect_assume_denied() {
  local role_arn="$1" token
  token="$(fetch_token)"
  echo "::add-mask::${token}"
  expect_denied "assume ${role_arn##*/} from this context" -- \
    aws sts assume-role-with-web-identity \
      --role-arn "$role_arn" \
      --role-session-name oidc-probe-should-fail \
      --web-identity-token "$token" \
      --duration-seconds 900
}

case "${1:-}" in
  claims)               claims ;;
  expect-denied)        shift; expect_denied "$@" ;;
  expect-assume-denied) shift; expect_assume_denied "${1:?role ARN required}" ;;
  *) die "usage: $0 claims | expect-denied <what> -- <cmd...> | expect-assume-denied <role-arn>" ;;
esac
