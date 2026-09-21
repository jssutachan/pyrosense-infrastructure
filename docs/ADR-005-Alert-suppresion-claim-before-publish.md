# ADR — Alert suppression: race-free slot, claimed before publishing

> **Number:** assign the next in your `docs/` sequence.
> **Status:** Accepted · 2026-09-21
> **Scope:** ingest core (`alerts.py`)

## Context

A burning sensor reports CRITICAL smoke every few seconds. Without suppression
that becomes hundreds of identical alert emails — and an operator who gets 300
emails stops reading them, which defeats the system. Multiple Lambda instances
may process CRITICAL messages for the **same** device concurrently.

## Decision

Gate each alert behind a **per-device suppression window** implemented as a
conditional write on an alert-state item (`ALERT#{device_id}`) in the same
DynamoDB table:

```
attribute_not_exists(pk) OR suppress_until < :now
```

Only the invocation that **wins** the conditional write may publish; the rest
count `AlertsSuppressed`. The slot is **claimed before** the SNS publish.

## Rationale

- The conditional write makes suppression **race-free** across concurrent
  instances with no locks, no leader, no coordination — the database resolves it.
- Claiming before publishing means two racing instances can never both publish:
  one wins the slot, the other never attempts the publish.
- Suppression limits **emails**, never **data** — the reading is always stored
  regardless of whether an alert goes out.

## Alternatives considered

- **Claim the slot *after* publishing** → **rejected**: two instances could both
  publish before either records the slot → duplicate email storms (the exact
  failure suppression exists to prevent).
- **No suppression** → **rejected**: alert storms; operators tune it out.
- **External lock / scheduler** → **rejected**: unnecessary coordination for what
  a single conditional write already guarantees.

## Consequences

- **Positive:** at most one alert per device per window, correct under
  concurrency, no coordination primitives.
- **Negative (accepted trade-off):** if the SNS publish fails *after* the slot is
  claimed, that single alert is lost for the remainder of the window (the message
  is retried, but on replay the slot is already taken). For an early-warning MVP,
  losing at most one alert on a rare SNS failure is preferable to email storms.
- **Follow-up (production hardening):** a two-phase claim — short reservation, then
  confirm-after-publish — would remove the lost-alert window without reintroducing
  duplicates. Revisit if alert delivery becomes mission-critical.
