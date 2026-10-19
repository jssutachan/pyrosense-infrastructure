## Proof it works

Tested end to end on AWS on 2026-10-15 (commit 981aae6): [full report](docs/evidence/README.md).

| | Result |
|---|---|
| Messages through the real pipeline | 15110 stored, **0 lost** |
| 502 simulated sensors over MQTT + mutual TLS | 6.34 msg/s · device-to-archive p95 1.06 s |
| 5,000-message burst | drained in 273 s, 0 errors, 0 throttles |
| Fire alert | reading-to-alert published p50 1.18 s · repeats suppressed |
| Injected failures (poison message, consumer outage, rule failure, lost alert) | all detected and paged; data recovered |
| Security probes (cross-environment publish, foreign client, plain HTTP) | all denied · 9/9 stores encrypted with a customer-managed key |
| Deploy from nothing / drift after tests | 105 s / one leftover caught by the drift check, fixed, final plan clean |

![Every boundary agrees](docs/evidence/v1.0-2026-10-15/charts/01-edge-to-storage.png)
