# Observed limits of the demo deployment (2026-10-15)

These are measured, not assumed. Each one is a deliberate demo constraint, with the production change it implies.

| Area | Measured in this run | Why it is like this in the demo | What production needs |
|---|---|---|---|
| Device edge throughput | 6.34 msg/s from one MQTT connection; PUBACK avg 158 ms, max 779 ms over 10040 messages; serial ceiling ~6.3 msg/s | One shared fleet identity: the IoT policy binds the client ID to one Thing, so connections cannot be parallel | Per-device certificates or fleet provisioning; each sensor holds its own connection (IoT Core: 100 publishes/s per connection) |
| Consumer drain rate | 18.3 msg/s with maximum concurrency 2 (5000-message burst drained in 273 s) | Concurrency capped on purpose; new account limit of 10 concurrent executions | Size maximum concurrency from backlog targets and downstream capacity; request a concurrency quota increase |
| Consumer concurrency cap | ConcurrentExecutions peaked at 3 with maximum concurrency set to 2, in 11 one-minute periods, at both low (~6.34 msg/s) and burst load | The setting is documented as limiting concurrent invocations by the event source; the documentation does not state it is a strict instantaneous ceiling | Do not rely on maximum concurrency as an exact limit when protecting a downstream resource; size that resource with headroom, or enforce the limit there |
| Alert channel | Email only; 5 alerts, reading-to-publish p50 1.18 s | Lowest-cost channel; SNS email is capped at 10 msg/s per subscription | Escalation channel (SMS/voice/on-call tool), per-recipient delivery monitoring, acknowledgement tracking |
| Lost alert on publish failure | Detected and paged (3 of 3), not recovered | Suppression slot is claimed before publishing to avoid duplicate alerts | Automatic slot release so the retry re-sends |
| Rule-failure recovery | Manual replay, byte-identical | Rare event at demo scale | Automated replay from the error log or an error action into a second queue |
| Recovery after a manual intervention | A consumer re-enable step did not take effect; only the drift check found it | Fault injections are run by hand from a runbook | Run recovery through the same automation that deploys (CI/CD), and alert on drift continuously, not only at the end of a test |
| Faults with no safe trigger | Lambda errors, throttles, SNS delivery failures proven by set-alarm-state only | No safe way to break them in a shared demo account | Fault injection in a staging account (for example AWS Fault Injection Service) |
| Lambda duration | max 2226 ms vs 30,000 ms timeout | Small payloads, stdlib-only code | Re-measure under production load before tuning timeout and visibility timeout together |
| Deployment | 105 s from nothing, applied from a laptop with manual approval of the plan | Single operator, ephemeral environment | CI/CD with protected environments and short-lived credentials |
| Region | Single region (us-east-1) | Cost | Multi-AZ is built into the managed services; multi-region only if the recovery objectives require it |
