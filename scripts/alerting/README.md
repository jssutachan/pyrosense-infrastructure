# scripts/alerting

Verification tooling for `modules/alerting`. Nothing here is deployed and
nothing changes infrastructure: the script only confirms a subscription you
were already going to confirm by hand.

| File | Purpose |
|---|---|
| `sns-confirm.sh` | Confirms an SNS email subscription with `--authenticate-on-unsubscribe true`, reading the link from stdin and printing only the subscription ARN — never the address (standard #11). |

Used in `RUNTIME-alerting.md` step 6.

## Usage

```bash
scripts/alerting/sns-confirm.sh      # paste the copied link when prompted, press Enter
```

Run it once per confirmation email. Needs the executable bit
(`chmod +x scripts/alerting/sns-confirm.sh`) and your normal credentials — **never
`sudo`**, which would make the inner `aws` look for root's credentials instead
of yours.

## What it does and why

It calls `ConfirmSubscription` with `--authenticate-on-unsubscribe true`
instead of letting you click the link. Clicking confirms *without* that flag.

Three deliberate details:

1. **The link is read from stdin, not passed as an argument.** It carries both
   the one-time token and your address; as an argument it would land in
   `~/.zsh_history`.
2. **It uses `unquote`, not `parse_qs`.** `parse_qs` applies form decoding,
   which turns a literal `+` in the token into a space and corrupts it.
   Tokens routinely contain `+`.
3. **It prints only `SubscriptionArn`.** Never the endpoint.

It exits non-zero with a `KeyError` if the link has no `Token` — that means
you pasted something other than the confirmation link.

## Known limitation: the flag could not be verified

> [!WARNING]
> On 2026-10-01 a subscription confirmed through this script was still
> successfully unsubscribed from the footer link of a delivered email, and
> `SubscriptionsConfirmed` dropped to `0`. Treat an email subscription as
> **removable by anyone holding a delivered message** until that is diagnosed.
> See ADR-0015 and the module README.

Two facts make this hard to verify in advance:

- `GetSubscriptionAttributes` returns no attribute exposing
  `AuthenticateOnUnsubscribe`. The only related attribute,
  `ConfirmationWasAuthenticated`, reports that the *confirmation request* was
  signed — which is true whenever you use the CLI, whether or not the flag took
  effect. **It is not proof that unsubscribe is protected.**
- The only real test is attempting the unsubscribe, and if the protection is
  absent the test leaves you unsubscribed.

Running the script is still correct: AWS's own CodeGuru detector flags *not*
setting the flag as a finding, and it costs nothing. Just do not treat it as a
guarantee.
