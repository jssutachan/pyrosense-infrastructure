#!/usr/bin/env bash
# Confirms an SNS email subscription WITH authentication on unsubscribe
# (ADR-0015, module README "Known risks"). Clicking the link in the email
# confirms WITHOUT it, which lets anyone holding a delivered alert unsubscribe
# the address from the email footer.
#
# The link is read from stdin, not passed as an argument, so neither the
# token nor the address it carries lands in shell history. Prints only the
# resulting subscription ARN — never the endpoint.
#
# Usage: scripts/sns-confirm.sh   (then paste the copied link and press Enter)
set -euo pipefail

printf 'Paste the "Confirm subscription" link (copied, NOT clicked): ' >&2
IFS= read -r LINK

# unquote, not unquote_plus / parse_qs: those turn a literal "+" into a space.
param() {
  python3 -c '
import sys, urllib.parse as u
query = u.urlparse(sys.argv[1]).query
pairs = dict(p.split("=", 1) for p in query.split("&") if "=" in p)
print(u.unquote(pairs[sys.argv[2]]))' "$LINK" "$1"
}

TOPIC=$(param TopicArn)
TOKEN=$(param Token)

aws sns confirm-subscription \
  --topic-arn "$TOPIC" \
  --token "$TOKEN" \
  --authenticate-on-unsubscribe true \
  --query SubscriptionArn --output text
