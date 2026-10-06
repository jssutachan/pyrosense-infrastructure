# scripts/

Helpers for verifying a deployment, one folder per module. None of them
changes infrastructure: `budget-check.jq` only reads a saved plan,
`sns-confirm.sh` only confirms a subscription you were already going to
confirm by hand, and `mqtt_smoke_publisher.py` only publishes test telemetry
to an IoT Core deployment that already exists.

The budgets and alerting helpers are designed so that **no email address ever
reaches stdout, a log, or the shell history**. That is a project standard
(#11), not a nicety: the addresses in this project are PII and the repository
is a portfolio artifact. The IoT helper handles no addresses; its equivalent
rule is #13: **the device private key never enters the repository, a log, or
Terraform state** — the script only receives its path.

| Folder | Script | Reads | Prints | Used in |
|---|---|---|---|---|
| `budgets/` | `budget-check.jq` | `tfplan.json` | Booleans and counts only | `RUNTIME-alerting.md` steps 0 and 1 |
| `alerting/` | `sns-confirm.sh` | A confirmation link on stdin | One subscription ARN | `RUNTIME-alerting.md` step 6 |
| `iot/` | `mqtt_smoke_publisher.py` | `PYROSENSE_*` settings (env file outside the repo) | Topic, `seq` and PUBACK latency per message; a summary | `RUNBOOK-iot.md` F1 and F7 (R5, R6) |
| `iot/` | `known-payload.json` | — (published with `aws iot-data publish`) | — | `RUNBOOK-iot.md` F7 (R4) |

Each folder has its own README with usage, rationale and known limitations:

- [`budgets/README.md`](budgets/README.md) — why the check compares values
  instead of asking whether the plan is a no-op, and why the sensitivity
  check recurses.
- [`alerting/README.md`](alerting/README.md) — why the link goes through
  stdin, why `unquote` and not `parse_qs`, and the unverified
  unsubscribe protection (ADR-0015).
- [`iot/README.md`](iot/README.md) — configuration shared with
  PyroSense-Simulator, negative tests, exit codes, and what a PUBACK does not
  prove.
