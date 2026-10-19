# ADR-0018: Topic rule → SQS, no filtering, error action to a dedicated log group

- **Status:** Proposed
- **Date:** 2026-09-24
- **Module:** `modules/iot`

## Context

Several constraints shape the rule:

- The ingest topology **IoT rule → SQS → Lambda** was chosen when an AI
  spec proposing rule → Lambda was rejected. ADR-0011 (retry contract)
  depends on the queue, but no ADR recorded the topology itself (debt #37).
- The payload contract is a closed key set (`contract.py`), and the
  consumer archives and parses the SQS body as-is.
- The AI draft sent the rule's `error_action` to the **messaging DLQ**,
  using the same role and the same CMK as the main action.

What AWS documents about the rule's error handling and metrics:

- The error action fires when an action fails. It receives one document
  per rule and message, with `ruleName`, `topic`, `clientId`,
  `base64OriginalPayload` and `failures[]`.
- SQL problems are not error-action territory: AWS points to IoT logging
  instead.
- Metrics: `TopicMatch`, `Success`/`Failure`, and
  `ErrorActionSuccess`/`ErrorActionFailure`, all with the `RuleName`
  dimension.

## Decision

1. **Topology:** rule → SQS standard queue → Lambda, formalized here. The
   SQS action does not support FIFO queues.
2. **SQL:** `SELECT * FROM '{base}/{env}/telemetry/+'`, `sql_version
   2016-03-23`, **no WHERE**, no added fields, `use_base64 = false`.
3. **Error action:** CloudWatch Logs, into a dedicated log group
   (`/aws/iot/<name_prefix>/topic-rule-errors`, 14-day retention, pipeline
   CMK). It is written by a **second IAM role** that has only Logs
   permissions.
4. **Account-level IoT logging** stays out of this module (the provider's
   delete is a no-op).

## Rationale

- **Why not the DLQ?** The DLQ has three problems as an error destination:
  - It shares the failure layer: same role, same service, same key.
  - Its messages would be of two kinds: raw payloads from redrive and IoT
    error documents. "Never redrive blindly" becomes impossible to follow.
  - It contradicts messaging's documented intent that the DLQ holds only
    the ingest queue's failures.
- **Why a second role?** Redundancy goes in the layer that fails
  (ADR-0015). The most plausible regression is an edit to the forwarding
  policy, and a separate identity keeps the error path working when that
  happens. Logs encrypts with the CMK as its own service principal, so the
  errors role needs no KMS permission.
- **Why no WHERE?** Under the fleet-client model (ADR-0016) the publisher
  controls both the topic and the payload. A `device_id = topic(n)` check
  therefore detects inconsistency, not spoofing. A message filtered out by
  WHERE is not an action failure, so it would not reach the error action;
  it would vanish with only the gap `TopicMatch` − `Success` as evidence.
  Without WHERE, a malformed or non-JSON payload reaches the consumer and
  is counted and dead-lettered (ADR-0012): visible.
- **Why 14 days?** It matches the DLQ triage window. The error document
  embeds the payload (coordinates), so it should not outlive the queue that
  holds the same data.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Error action → messaging DLQ (AI draft) | Same failure layer; mixes document types; breaks "never redrive blindly". |
| Error action → S3 | Needs `storage` (destroyed in iot cycles) or a new bucket with its own encryption, TLS policy and public-access block. It would also pollute the Hive-partitioned telemetry archive. |
| Error action → ops SNS topic | One email per failed message: floods responders and hits the email throttle (debt #28). |
| No error action | A failed delivery leaves only the `Failure` counter; the payload is unrecoverable. |
| WHERE anti-spoofing filter | No security value under ADR-0016; converts visible failures into silent drops. |

## Consequences

- Recovery from the error log is manual: decode `base64OriginalPayload` and
  republish. No automated replay.
- If the CMK is disabled, both paths fail. `ErrorActionFailure` is the last
  signal, so `modules/observability` must alarm on `Failure`,
  `ErrorActionSuccess` and `ErrorActionFailure`.
- Debt #37 (master design says rule → Lambda) now has an ADR to point to.
  The document itself still needs the correction.

## Revision trigger

- A second consumer of the telemetry stream.
- A need for automated replay of failed deliveries.
- A move away from the fleet-client model, which would re-evaluate a
  gateway/device consistency check.
