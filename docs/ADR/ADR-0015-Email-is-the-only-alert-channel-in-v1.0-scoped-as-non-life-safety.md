# ADR-0015: Email is the only alert channel in v1.0, scoped as non-life-safety

- **Status:** Proposed
- **Date:** 2026-09-23 — revised 2026-10-01 twice: the FIFO and encryption-reach consequences, then the falsified unsubscribe control (runtime evidence)
- **Scope:** `modules/alerting`, `src/ingest_lambda/alerts.py` (follow-up), portfolio README
- **Related:** ADR-0002 (design for production), ADR-0005 (claim-before-publish), ADR-0008 (idempotent conditional writes), ADR-0009 (log field whitelist), ADR-0014 (alerting module shape)

## Context

PyroSense exists to shorten the time between a sensor reading smoke and a
human responder acting on it. v1.0 delivers alerts only as SNS email. What AWS
documents about that channel:

| Property | What AWS documents |
|---|---|
| Throughput | **10 messages/s per email subscription, hard limit.** Exceeding it suspends the subscription into `PendingConfirmation` for **30 days** |
| Retries | SMTP is a customer-managed endpoint: 50 attempts over 6 hours, then the message is discarded |
| Observability | No delivery status logging for email |
| Bounces | Bounced addresses are suppressed for 7 days |
| Confirmation | Each address must be confirmed by a human; unconfirmed subscriptions are deleted after 48 hours |
| Unsubscribe | Every delivered email carries a footer unsubscribe link. `sns:Unsubscribe` is **not** one of the 11 actions a topic policy can control, so it cannot be denied there |
| Intent | "The email delivery feature is intended to provide internal system alerts" |
| Latency | No latency guarantee in the FAQ or developer guide |

Two failure modes already exist upstream of the channel:

1. **Publish-side loss (ADR-0005).** The suppression slot is claimed before
   `Publish`. If `Publish` fails, the SQS retry finds the window closed and the
   alert is dropped. The handler counts that retry as `AlertsSuppressed` and
   logs nothing CRITICAL. The loss has no signal of its own.
2. **Retry latency.** Any transient failure before `Publish` (S3, DynamoDB)
   delays the alert by at least one visibility timeout (180 s, ADR-0011).

## Decision

1. v1.0 ships **email-only**, and the README and the portfolio state
   explicitly that it is a **demo alerting path, not a life-safety
   notification system**.
2. Before v1.0 is tagged, the ingest code must make publish-side loss
   observable: an EMF metric for failed alert publishes, alarmed on the ops
   topic. A second channel is not a substitute for this.
3. The 10 msg/s per-subscription throttle is recorded as the main open risk,
   with a falsifiable failure scenario (below). Mitigation is deferred to the
   first revisit trigger.

## Rationale

- **A second channel protects the wrong layer.** SNS fans out *after* a
  successful `Publish`. If `Publish` fails, which is the loss ADR-0005 already
  accepts, email and SMS both receive nothing. Redundancy of subscribers does
  not help publish-side failures. Making that failure visible does.
- **The concrete alternative, SMS via SNS, is not a quick win in Colombia.**
  AWS lists Colombia as supporting **short codes only** (no long codes, no
  sender IDs, no two-way). A dedicated short code is a provisioning process,
  not a Terraform argument. New accounts start with a 1.00 USD SMS spend
  threshold. SMS availability on the Free plan is unverified. SMS would win
  on human attention (a phone buzzes; an inbox is polled), but only after a
  procurement step outside this project's reach.
- **The throttle is the real channel risk, and it is triggered by the most
  plausible disaster pattern.** Suppression is per device, not per recipient.
  Suppose the Lambda is down or throttled for a few minutes while a fire front
  crosses the grid. When the backlog drains, dozens of distinct devices can
  each win their slot within the same second. Every publish fans out to the
  same email subscription. More than 10 in one second suspends that
  subscription for 30 days, and no alert reaches that recipient until someone
  reconfirms.

**Falsifiable claim:** a burst of more than 10 CRITICAL messages from distinct
devices, processed within one second, moves the fire-alert email subscription
to `PendingConfirmation`. Do not test this against a real inbox: the
suspension lasts 30 days.

## Alternatives considered

| Alternative | Why not in v1.0 |
|---|---|
| SMS via SNS in parallel with email | Colombia supports short codes only (provisioning outside Terraform). Free-plan availability [?]. Does not fix publish-side loss |
| HTTPS subscription to a paging service | Adds a third-party account and a secret; auto-confirm endpoint. Does not fix publish-side loss |
| Aggregate alerts per Lambda invocation (one publish per batch listing all newly CRITICAL devices) | Directly addresses the throttle. Changes `alerts.py` and the ADR-0005 contract; deferred as the first mitigation |
| `email-json` instead of `email` | Same throttle and retries. Harder for a human to read |

## Consequences

- The portfolio claim is "event-driven alerting pipeline with suppression",
  not "wildfire early-warning notification to responders".

- **Choosing email forecloses FIFO topics, and with them ordering guarantees.**
  AWS: *"SNS FIFO topics can't deliver messages to customer managed endpoints,
  such as email addresses, mobile apps, phone numbers for text messaging (SMS),
  or HTTP(S) endpoints… Attempts to subscribe customer managed endpoints to SNS
  FIFO topics result in errors."* FIFO delivers only to SQS queues. This is not
  a loss: the approved `alerts.py` sends no `MessageGroupId`, which FIFO
  requires on every message; the ingest queue upstream is standard, so ordering
  was already lost before SNS; and FIFO's content-based deduplication would not
  deduplicate anything here, because two CRITICAL readings seconds apart differ
  in `seq`, `ts_device` and `smoke_ppm`. Deduplication is solved by the
  DynamoDB suppression slot, per device and over the suppression window
  (ADR-0005, ADR-0008). The topics are therefore standard, stated explicitly in
  the code rather than left to the provider default.

- **Encryption at rest has a bounded reach, and the README says so.** SSE
  protects a real window: SNS stores the message between `Publish` and delivery
  to every subscriber, and for email that window can reach 6 hours. But SSE
  covers the message *body* only — AWS: *"SSE doesn't encrypt… Message metadata
  (subject, message ID, timestamp, and attributes)"* — so the `device_id` that
  `alerts.py` puts in the `Subject` is stored unencrypted while the coordinates
  in the body are not. That split matches ADR-0009, which whitelists
  `device_id` for logs and excludes coordinates. And protection ends at
  delivery: once the email arrives, the whole message sits in a mailbox in
  plaintext indefinitely. The CMK buys confidentiality for the in-AWS window
  and a CloudTrail audit trail of every decrypt; it does not buy end-to-end
  confidentiality, and no document in this repository may imply that it does.

- **Every deploy cycle needs a human.** Email subscriptions are confirmed by a
  person clicking a link, and the demo cycle recreates them on every apply. Until
  confirmation, SNS delivers nothing and `Publish` still reports success. This
  is a recurring operational cost of the channel, not a defect, and the runbook
  in the module README treats it as a step.

- **Anyone holding a delivered alert can remove the recipient, and the
  intended control did not hold.** This ADR's first revision claimed that
  confirming with `--authenticate-on-unsubscribe true` mitigated footer
  unsubscribes. **Runtime on 2026-10-01 falsified that claim**: a subscription
  confirmed through `scripts/sns-confirm.sh` was unsubscribed from the footer
  link of a delivered email and `SubscriptionsConfirmed` fell to `0`. The
  mechanism is real — AWS documents that an authenticated-unsubscribe
  subscription refuses the link — so the gap is in how it was applied here, and
  it is undiagnosed. Two properties make it a weak control regardless:
  `GetSubscriptionAttributes` exposes no attribute for the flag, so it cannot be
  verified before trusting it; and the only test consumes the thing it tests.
  Treat an email recipient as **removable by any holder of a delivered
  message**. This is a consequence of choosing email, not of this module's
  design: a topic policy cannot deny `sns:Unsubscribe`.

- `AllowSNSDelivery` in the key policy remains unused in v1.0: it exists for
  SNS delivering to an encrypted SQS subscription DLQ, and whether email
  subscriptions support a DLQ at all is not stated in the SNS docs [?].

- Follow-up tasks: (a) failed-publish metric and alarm (ingest +
  observability); (b) set `alerts._MAX_SUBJECT` to 99, since SNS requires the
  subject to be *less than* 100 characters — unreachable today because
  `device_id` matches `PYRO-T[123]-\d{4}` and is 12 characters, so the subject
  tops out at 46; (c) diagnose the failed unsubscribe control against CloudTrail
  (see the module README), and if it cannot be made to hold, decide between the
  two mitigations below.

## Mitigations for the unsubscribe gap, in order of proportionality

Prevention by policy is unavailable (`sns:Unsubscribe` is not a topic-policy
action), so the options are detection or an endpoint that has no human.

1. **Detect the drift (preferred for v1.0).** Terraform owns the subscription,
   so a `terraform plan` reports a removed recipient as a resource to create.
   That turns into real detection once the Terraform CI workflow exists and
   runs on a schedule, which is already an open debt item. Cost: zero new
   infrastructure.
2. **Give the fire topic a subscriber that cannot unsubscribe itself.** An SQS
   queue subscribed to the fire topic has no footer, no human and no
   unsubscribe email, so it keeps receiving alerts after every human recipient
   is gone, and becomes the durable record. It also gives `AllowSNSDelivery` in
   the pipeline key policy its first real user — SNS calls KMS as itself when
   delivering to an encrypted queue, which is exactly what that unused
   statement authorizes. Cost: one free-tier queue, plus a queue policy
   allowing `sns.amazonaws.com` to `SQS:SendMessage` conditioned on the topic
   ARN. Trade-off: it widens this module beyond "notification layer", and a
   queue nobody consumes is itself a mechanism without a receiver unless
   `observability` alarms on its depth.
3. **CloudTrail → EventBridge on the `Unsubscribe` event.** Real-time, but it
   has to notify somewhere, and the obvious destination is the ops topic, which
   has the same weakness. Only coherent on top of option 2.

## Revisit triggers

- Any real stakeholder pilot (Bomberos, IDIGER) → email-only is no longer
  acceptable; add a push channel and per-invocation aggregation.
- The simulated fleet or the backlog-drain test can produce more than 10
  CRITICAL publishes per second → implement aggregation before the next
  runtime test.
- A non-email protocol is added to either topic → re-evaluate whether a
  subscription DLQ becomes mandatory, which would give `AllowSNSDelivery` its
  first user.
- The unsubscribe diagnosis concludes that the control cannot be made to hold
  → adopt mitigation 2 before any stakeholder pilot.
- AWS changes the email per-subscription quota or adds delivery status
  logging for email.

## References

- Email subscriptions (48 h pending, 10 TPS suspension for 30 days, bounce suppression, "internal system alerts"): https://docs.aws.amazon.com/sns/latest/dg/sns-email-notifications.html
- SNS quotas (10 msg/s per email subscription, hard limit; SMS spend threshold): https://docs.aws.amazon.com/general/latest/gr/sns.html
- Delivery retries (SMTP: 50 attempts over 6 hours, then discard): https://docs.aws.amazon.com/sns/latest/dg/sns-message-delivery-retries.html
- Delivery status logging endpoints (no email): https://docs.aws.amazon.com/sns/latest/dg/sns-topic-attributes.html
- FIFO message delivery (FIFO topics deliver only to SQS; customer managed endpoints error on subscribe): https://docs.aws.amazon.com/sns/latest/dg/fifo-message-delivery.html
- Server-side encryption (what SSE encrypts and what it does not): https://docs.aws.amazon.com/sns/latest/dg/sns-server-side-encryption.html
- SMS supported countries (Colombia: short codes only): https://docs.aws.amazon.com/sns/latest/dg/sns-supported-regions-countries.html
- Publish API (`MessageGroupId` required on FIFO; Subject < 100 characters; message ≤ 256 KB): https://docs.aws.amazon.com/sns/latest/api/API_Publish.html
- Unsubscribe API ("If the subscription requires authentication for deletion, only the owner of the subscription or the topic's owner can unsubscribe, and an AWS signature is required"): https://docs.aws.amazon.com/sns/latest/api/API_Unsubscribe.html
- GetSubscriptionAttributes (no attribute exposes AuthenticateOnUnsubscribe): https://docs.aws.amazon.com/sns/latest/api/API_GetSubscriptionAttributes.html
- Valid topic-policy actions (11; `sns:Unsubscribe` is not among them): https://docs.aws.amazon.com/sns/latest/dg/sns-access-policy-language-api-permissions-reference.html
- CodeGuru detector, unauthenticated unsubscribe requests might succeed: https://docs.aws.amazon.com/codeguru/detector-library/javascript/sns-authenticate-on-unsubscribe/
- SNS FAQ (pricing; no latency guarantee stated): https://aws.amazon.com/sns/faqs/
