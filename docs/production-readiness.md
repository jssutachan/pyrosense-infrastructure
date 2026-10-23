# PyroSense — Production readiness

PyroSense v1.0 is a demo deployment of a production design. It has been tested end to end on AWS ([evidence](evidence/README.md)), but a working pipeline is not the same as a system that a fire department can rely on. This document lists what would have to change before anyone used it, or this infrastructure, to protect real people and land.

It is written for two readers:
- **A reviewer**, to show which limitations are known, why they exist, and what closing each one would take.
- **Anyone who wants to build a real detection system on this infrastructure**, as a checklist of what to address first.

The structure follows the questions a production readiness review asks (architecture, failure modes, capacity, security, operations, delivery), in the spirit of the [Google SRE launch checklist](https://sre.google/sre-book/reliable-product-launches/) and [AWS Operational Readiness Reviews](https://docs.aws.amazon.com/wellarchitected/latest/operational-readiness-reviews/wa-operational-readiness-reviews.html).

**Priority**
- 🔴 **Before any real use:** without it, the system could fail people who depend on it.
- 🟠 **Before scale:** required as the fleet, the users or the traffic grow.
- 🟢 **Improvement:** reduces cost, effort or risk, but does not block use.

---

## 1. Alert delivery: the last mile

The pipeline can detect a fire in about a second. That is worth nothing if the alert does not reach a person who acts on it.

### 🔴 Email is the only channel, and email is not a life-safety channel
- **Today:** fire alerts go to email subscribers of an SNS topic. ADR-0015 scopes v1.0 explicitly as non-life-safety.
- **Why it is a problem:**
  - Email has no delivery guarantee, no acknowledgement and no escalation. An alert can sit unread in an inbox at 3 a.m.
  - SNS email is limited to 10 messages per second per subscription, and exceeding it suspends the subscription.
- **What production needs:**
  - At least two independent channels for every alert: for example SMS or voice, plus an on-call or dispatch tool.
  - An **acknowledgement step**: an alert is not handled until a person confirms it.
  - **Escalation** to the next person or agency if nobody acknowledges within a set time.
  - Integration with the stakeholders' own dispatch systems, rather than personal inboxes.

### 🔴 Subscribers can be removed by anyone holding an alert email
- **Today:** a subscription confirmed by clicking the email link can be cancelled by anyone who has a copy of an alert, for example a forwarded email. The runbooks confirm subscriptions from the CLI with authenticated unsubscribe, but nothing enforces it.
- **Why it is a problem:** a recipient can silently stop receiving fire alerts. Nobody is told; the alert is "delivered" to fewer people.
- **What production needs:**
  - A **subscriber onboarding procedure**: subscriptions confirmed through the API with unsubscribe protection, never by clicking a link.
  - **Continuous detection** of removed subscribers, for example a scheduled Terraform plan that reports a missing subscription as drift, or an event rule on unsubscribe.
  - Alert recipients managed as **roles** (duty desk, on-call engineer), not as individual addresses.

### 🔴 A failed alert is detected, but not re-sent
- **Today:** to avoid duplicate alerts, the system reserves the right to alert for a sensor **before** publishing. If the publish then fails (for example, a permission or encryption error), the retry finds the slot already taken and the alert is not sent. The loss is counted, logged with the sensor ID and paged to the operator (tested in E4d), but recovery is manual.
- **What production needs:** an automatic recovery, so that a failed publish releases the slot and the retry sends the alert, plus a periodic check that every critical reading has a matching delivered alert.

### 🟠 Delivery failures after publishing are only partly visible
- **Today:** an alarm watches SNS delivery failures, but email bounces are not tracked per recipient.
- **What production needs:** per-recipient delivery status, and an alarm when a specific responder stops receiving alerts.

---

## 2. Time to alert when something goes wrong

The design guarantees that **no message is lost**. It does not yet guarantee that a critical message is **fast** when something fails.

### 🔴 A critical reading inside a failing message waits about 15 minutes
- **Today:** a message that cannot be processed is retried every 180 seconds, 5 times, before it moves to the dead-letter queue: about **15 minutes** in total. Then it waits for a person to triage it. This applies to every kind of failure:
  - a payload that breaks the data contract (a firmware bug, a corrupted field);
  - a dependency that keeps failing (S3, DynamoDB, KMS);
  - a permission or encryption error after a configuration change.

  If that message carried a smoke reading of 80 ppm, the alert would be delayed by at least 15 minutes, plus the time until someone looks at the dead-letter queue.
- **Why it is designed this way:** retrying protects against transient failures, and a strict contract stops bad data from reaching the decision logic (ADR-0006, ADR-0012). Both are correct for data integrity; neither is tuned for urgency.
- **What production needs:**
  - **Separate permanent from transient failures.** A message that breaks the contract will never succeed, so retrying it 5 times only adds delay. Move it to the dead-letter queue on the first attempt.
  - **A safety net for critical values in rejected messages.** Before rejecting a message, check whether it contains a recognisable smoke or temperature value above the critical threshold; if it does, raise an alert marked "unverified reading" while the message goes to triage. Missing a real fire costs far more than a false alarm.
  - **A dead-letter queue with an owner and a time limit:** triage within minutes, around the clock, not "when someone looks".
  - **An explicit service-level objective,** for example "99 % of critical readings alerted within 60 seconds", measured continuously and alarmed when breached.

### 🟠 The archive is written before the alert
- **Today:** the Lambda archives the raw message in S3 before it evaluates and publishes an alert. If S3 is failing, the alert waits for the retry (180 s or more).
- **What production needs:** evaluate and alert first, archive second, with the archive still guaranteed by the retry. Data integrity does not depend on the order; alert latency does.

### 🟠 Rule failures are recovered by hand
- **Today:** if the IoT rule cannot reach the queue, the message is kept in an error log and an alarm pages. The replay is a manual procedure (proven byte-identical in E4c).
- **What production needs:** an automated replay, or an error action that writes to a second queue the consumer also reads.

---

## 3. Sensors and the edge

### 🔴 The fleet shares one identity
- **Today:** all simulated sensors connect with one certificate (ADR-0016). Any process holding it can publish readings in the name of any sensor ID that matches the expected pattern.
- **What production needs:**
  - One certificate per physical sensor, provisioned at manufacturing or first boot (for example with AWS IoT fleet provisioning).
  - A policy that ties each certificate to its own sensor ID and topic.
  - A **revocation process** for stolen or decommissioned devices.

### 🔴 Silence is detected for the whole fleet, not per sensor
- **Today:** the heartbeat alarm fires when **no** sensor reports for 10 minutes. One dead sensor among 500 goes unnoticed.
- **Why it is a problem:** a sensor in the highest-risk area that dies (battery, theft, fire damage) leaves a blind spot exactly where it matters, and nothing pages.
- **What production needs:** per-sensor and per-zone liveness: track the last reading of each sensor, alarm when a sensor or a high-risk zone goes quiet, and report battery and status trends before they fail.

### 🟠 Edge throughput was measured on a single connection
- **Measured:** 6.3 messages per second from one connection waiting for each acknowledgement. The production model needs about 10.7 (see [observed limits](evidence/v1.0-2026-10-15/observed-limits.md)).
- **Why it is not a design problem:** real sensors each hold their own connection, so their load spreads across many connections. It must still be load-tested that way before go-live.

### 🟠 Sequence numbers and device clocks are trusted
- **Today:** duplicates are discarded by sensor ID and sequence number. A sensor whose counter resets after a reboot would have its new readings discarded as duplicates.
- **What production needs:** a sequence scheme that survives reboots (for example a boot counter in the key), and checks on device clock drift.

---

## 4. Detection logic

### 🔴 The detection rule is a placeholder
- **Today:** a reading is critical when smoke is at or above 5 ppm. The values are provisional and have no domain owner (ADR-0020). A second rule (high temperature with low humidity) adds context but never alerts.
- **What production needs:**
  - Thresholds set and owned by fire-behaviour experts, calibrated against the actual sensor hardware and local conditions.
  - **Multi-sensor correlation:** neighbouring sensors confirming each other, to cut false alarms without slowing true ones.
  - Measured false-positive and false-negative rates, reviewed after every fire season.

---

## 5. Capacity and scaling

### 🟠 Consumer concurrency and account quotas
- **Measured:** the consumer drained 18.3 messages per second with its concurrency capped at 2. The account's default limit is 10 concurrent executions. The metric briefly showed 3 concurrent executions despite the cap of 2: the setting limits concurrency but is not documented as an exact ceiling.
- **What production needs:**
  - Concurrency sized from a backlog target, for example "a burst from all sensors drains in under 60 seconds".
  - Account quota increases requested in advance.
  - Downstream limits enforced where they matter, not only at the consumer.

### 🟢 Archive cost at scale
- **Today:** every reading is a separate S3 object. At production volume, S3 write requests become the largest cost item.
- **What production needs:** batch readings into larger objects (for example hourly per zone) before archiving. A full cost model with AWS Pricing Calculator is the next planned stage.

---

## 6. Security

### 🟠 Remaining hardening items
- **DynamoDB:** add a TLS-only resource policy (the queue, bucket and topics already have one).
- **IoT rule role:** restrict its use of the encryption key to requests made through SQS, as the consumer's role already does.
- **Terraform state:** it holds subscriber email addresses in plain text, protected by S3 server-side encryption only. Use the customer-managed key, and restrict who can read the state.
- **Account level:** CloudTrail organization trail, GuardDuty and Security Hub with alerts. They are outside this project's scope, but a production account needs them.

### 🟢 Verified today
Already verified: least-privilege IAM (no wildcards; IAM Access Analyzer clean), a customer-managed key on every data store, TLS enforced by policy, and private keys kept out of Terraform. All in [E5](evidence/README.md).

---

## 7. Operations

### 🔴 Recovery steps must be automated
- **Observed:** during the test run, a manual recovery step after a fault injection did not take effect, and only the final drift check found it. The queue held every message in the meantime, as designed, but a real outage would have lasted until someone ran that check.
- **What production needs:**
  - Every deployment and recovery runs through the same automation: the CI/CD pipeline, the next stage of this project.
  - Drift detection runs on a schedule, not only at the end of a test.

### 🟠 People and process
- An on-call rotation for the operations alarms, with runbooks linked from each alarm.
- A named owner for the dead-letter queue, the detection policy and the subscriber list.
- Incident reviews after every missed or late alert.

### 🟠 Faults that were not tested for real
- Lambda errors, Lambda throttling and email delivery failures were proven only through their notification path, because there is no safe way to trigger them in a shared demo account.
- **What production needs:** fault-injection exercises in a staging account (for example with AWS Fault Injection Service), run on a schedule.

---

## 8. Availability and recovery

### 🟠 One region
- **Today:** everything runs in one AWS region. The managed services spread across availability zones within it, but a regional outage would stop ingestion.
- **What production needs:** recovery objectives agreed with the stakeholders (how long can detection be down? how much data may be lost?), then a second-region design if those objectives require it. IoT endpoints and certificates are regional, so this affects the devices too.

---

## 9. Delivery pipeline (CI/CD)

The quality gate runs on every pull request as required checks, with a pinned, hash-verified toolchain (ADR-0022). These are the parts a team deploying this for real would still have to add.

### 🔴 One person writes, reviews and merges every change
- **Today:** the project has a single maintainer. The ruleset requires a pull request and green checks, but zero approvals, because nobody can approve their own pull request.
- **Why it is a problem:** the checks catch what they are written to catch. A wrong threshold, a weakened IAM condition or a removed alarm passes every check and reaches the main branch with nobody else having read it.
- **What production needs:**
  - At least two people with write access, and at least one required approval on the ruleset, with stale approvals dismissed on new pushes.
  - Code owners for the sensitive paths (IAM, the key policy, the detection policy, the workflows).
  - "Prevent self-review" on the deployment environments, so the person who triggers a deploy cannot also approve it.

### 🟠 Only direct Python dependencies are locked
- **Today:** `requirements-dev.txt` pins each direct dependency exactly; the packages they pull in are resolved at install time.
- **What production needs:** a full lock with hashes (`uv lock` or `pip-compile --generate-hashes`), installed with `--require-hashes`, so CI and every developer install byte-identical packages.

### 🟠 Pins do not update themselves
- **Today:** actions, binaries and Python packages are pinned; a version bump is a manual, reviewed change.
- **Why it is a problem:** pins without an update process age, and a known vulnerability stays in the toolchain until someone notices.
- **What production needs:** an update bot (Dependabot or Renovate) covering actions, Python packages, pre-commit hooks and the binaries in `.tool-versions`, with a cooldown before new releases are adopted, and an owner who reviews its pull requests every week.

### 🟠 Secrets need a response procedure, not only detection
- **Today:** secrets are blocked at three points: the pre-commit hook, GitHub push protection and a CI scan of the full history.
- **Why it is a problem:** in a public repository a secret is exposed the moment it is pushed, so detection after the push is already a leak.
- **What production needs:** a written rotation procedure for every credential type, rehearsed, with an owner who can revoke a key within minutes.

### 🟠 A private repository changes what is available
- **Today:** the repository is public, which makes Actions minutes free on standard runners and makes rulesets, environments, required reviewers and environment secrets available on the free plan.
- **What production needs:** a production repository is usually private. Check the GitHub plan before relying on these features, and budget for Actions minutes.

### 🟢 Hashes prove integrity, not origin
- **Today:** each binary must match a SHA-256 recorded in the repository when it was pinned.
- **What production needs:** verify signatures or build attestations as well (cosign, `gh attestation verify`), which prove who built the artifact, not only that it has not changed since it was pinned.

### 🟢 The provider lock covers one platform
- **Today:** `.terraform.lock.hcl` was generated on Linux, which matches the CI runners.
- **What production needs:** a team on macOS and Linux records provider hashes for every platform (`terraform providers lock -platform=...`), or `terraform init` fails on one of them.

---

## Summary

| Area | 🔴 Before real use | 🟠 Before scale |
|---|---|---|
| Alert delivery | Multiple channels with acknowledgement and escalation · protected subscriber list · automatic re-send of failed alerts | Per-recipient delivery tracking |
| Time to alert | Fast path for permanent failures · alert on critical values in rejected messages · dead-letter triage SLA · alert-latency SLO | Alert before archive · automated rule replay |
| Sensors | Per-device identity and revocation · per-sensor liveness | Load test with per-device connections · reboot-safe sequence numbers |
| Detection | Expert-owned, calibrated thresholds with multi-sensor correlation | — |
| Capacity | — | Concurrency and quotas sized from targets |
| Security | — | DynamoDB TLS policy · scoped key use for the IoT role · state encrypted with the managed key · account guardrails |
| Operations | Automated deployment and recovery (CI/CD) · scheduled drift detection | On-call and ownership · scheduled fault injection |
| Availability | — | Recovery objectives and a second-region design if needed |
| Delivery pipeline | Independent review of every change (two maintainers, required approvals, code owners) | Locked transitive dependencies · update bot with cooldown · secret rotation procedure · plan check for a private repository |
