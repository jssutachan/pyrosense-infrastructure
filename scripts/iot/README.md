# scripts/iot

Runtime test tooling for `modules/iot`. Nothing here is deployed and nothing
changes infrastructure: the script only publishes test telemetry to an IoT
Core deployment that already exists.

| File | Purpose |
|---|---|
| `mqtt_smoke_publisher.py` | Minimal MQTT publisher: one mutual-TLS connection, a few contract-v1 payloads at QoS 1, one line per PUBACK. No retries, so every failure is visible once. |
| `known-payload.json` | Fixed contract-v1 payload for the byte-identity test (the comparison ignores the trailing newline that pre-commit adds): published with `aws iot-data publish`, compared with the SQS message body. |
| `requirements.txt` | AWS IoT Device SDK for the smoke publisher, isolated from the Lambda and the dev tooling. |

Used in `RUNBOOK-iot.md` F1 and F7 (R4, R5, R6).

## Setup

Run from the **repository root**, so the virtualenv lands at `./.venv-iot`
(the path `trivy.yaml` skips and the runbook uses):

```bash
python3.12 -m venv .venv-iot          # .venv*/ is gitignored
.venv-iot/bin/pip install -r scripts/iot/requirements.txt
```

## Configuration

The script reads the same `PYROSENSE_*` variables as PyroSense-Simulator, from
`--env-file` or the environment. Build the file from the root outputs after
apply (runbook step in `modules/iot/README.md`) and keep it outside the
repository, e.g. `~/.config/pyrosense/iot-demo.env`. Write the certificate
paths as absolute paths: this script expands `~`, but the simulator reads the
same variables through pydantic-settings, which does not. Relative paths
resolve against the current directory, not the env file.

## Runs

```bash
# Offline: print the payloads and validate them with the consumer contract
PYTHONPATH=src .venv-iot/bin/python scripts/iot/mqtt_smoke_publisher.py --dry-run

# Happy path: 3 sensors x 2 messages
.venv-iot/bin/python scripts/iot/mqtt_smoke_publisher.py --env-file ~/.config/pyrosense/iot-demo.env

# Negative tests (same certificate; the IoT policy must reject them)
.venv-iot/bin/python scripts/iot/mqtt_smoke_publisher.py --env-file ... --topic-env prod
.venv-iot/bin/python scripts/iot/mqtt_smoke_publisher.py --env-file ... --client-id pyrosense-demo-other
```

Exit codes: `0` every publish acknowledged, `1` at least one failure,
`2` configuration error.

## What a PUBACK proves, and what it does not

A PUBACK means the broker accepted the message. It does not mean the topic
rule delivered it to SQS. Always confirm on the other side: the rule's
`TopicMatch` / `Success` metrics and the queue depth.
