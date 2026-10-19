"""Minimal MQTT publisher to smoke-test modules/iot against real AWS IoT Core.

Why this exists: PyroSense-Simulator is the real publisher, but its MQTT path
has never touched a broker and carries a known reconnection bug (see the
simulator patch). This script isolates ONE question: does the boundary that
modules/iot deploys (certificate + Thing + IoT policy + topic rule -> SQS)
work end to end? It opens one mutual-TLS connection, publishes a few
contract-v1 payloads at QoS 1, waits for each PUBACK and reports.

It deliberately has no retries, no reconnection logic and no fleet engine:
every failure is printed once, with its exception type, so a test result
cannot be masked by a retry loop.

Configuration comes from an env file (or the environment) using the same
variable names as PyroSense-Simulator, so `terraform output iot_simulator_env`
feeds both:

    PYROSENSE_IOT_ENDPOINT, PYROSENSE_TOPIC_BASE, PYROSENSE_ENV,
    PYROSENSE_CLIENT_ID, PYROSENSE_CERT_PATH, PYROSENSE_PRIVATE_KEY_PATH,
    PYROSENSE_ROOT_CA_PATH

Usage (from the infrastructure repo root):

    PUB=scripts/iot/mqtt_smoke_publisher.py
    ENV=~/.config/pyrosense/iot-demo.env
    python $PUB --env-file $ENV
    python $PUB --dry-run
    python $PUB --env-file $ENV --topic-env prod       # negative test
    python $PUB --env-file $ENV --client-id other      # negative test

Exit codes: 0 all publishes acknowledged, 1 at least one failed, 2 bad config.
"""

from __future__ import annotations

import argparse
import importlib
import json
import os
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from types import ModuleType
from typing import Any

PUBACK_TIMEOUT_S = 10.0
CONNECT_TIMEOUT_S = 15.0

REQUIRED_VARS = (
    "PYROSENSE_IOT_ENDPOINT",
    "PYROSENSE_TOPIC_BASE",
    "PYROSENSE_ENV",
    "PYROSENSE_CLIENT_ID",
    "PYROSENSE_CERT_PATH",
    "PYROSENSE_PRIVATE_KEY_PATH",
    "PYROSENSE_ROOT_CA_PATH",
)
PATH_VARS = (
    "PYROSENSE_CERT_PATH",
    "PYROSENSE_PRIVATE_KEY_PATH",
    "PYROSENSE_ROOT_CA_PATH",
)

# Cerros Orientales de Bogota, around the January 2024 fire area.
BASE_LAT = 4.620
BASE_LON = -74.040


# ---------------------------------------------------------------------------
# Optional modules
# ---------------------------------------------------------------------------


def optional_module(name: str) -> ModuleType:
    """Import a module that is not available everywhere.

    The AWS IoT Device SDK ships no type information (no py.typed) and is not
    needed for --dry-run; the consumer contract is importable only with
    PYTHONPATH=src. Importing them dynamically keeps mypy --strict clean in
    every environment without type-ignore comments that would be "unused" in
    some setups and required in others.
    """
    return importlib.import_module(name)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def load_env_file(path: Path) -> dict[str, str]:
    """Parse KEY=VALUE lines; blank lines and # comments are ignored."""
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise ValueError(f"{path}: line without '=': {line!r}")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def resolve_config(args: argparse.Namespace) -> dict[str, str]:
    """Merge env file over the process environment, apply CLI overrides, expand ~."""
    config = {name: os.environ[name] for name in REQUIRED_VARS if name in os.environ}
    if args.env_file:
        config.update(load_env_file(Path(args.env_file).expanduser()))

    # CLI overrides exist for the negative tests: same certificate, wrong env
    # or wrong client ID, so the IoT policy is what rejects the request.
    if args.topic_env:
        config["PYROSENSE_ENV"] = args.topic_env
    if args.client_id:
        config["PYROSENSE_CLIENT_ID"] = args.client_id

    missing = [name for name in REQUIRED_VARS if not config.get(name)]
    if missing:
        raise ValueError(f"missing configuration: {', '.join(missing)}")

    # pydantic-settings in the simulator does not expand "~"; this script does,
    # so the same env file works with either.
    for name in PATH_VARS:
        path = Path(config[name]).expanduser()
        if not path.is_file():
            raise ValueError(f"{name} points to a file that does not exist: {path}")
        config[name] = str(path)

    if config["PYROSENSE_IOT_ENDPOINT"].startswith(("http://", "https://")):
        raise ValueError("PYROSENSE_IOT_ENDPOINT must be a host name only, without scheme")
    return config


# ---------------------------------------------------------------------------
# Payloads (contract v1: contract.py in src/ingest_lambda)
# ---------------------------------------------------------------------------


def device_ids(count: int) -> list[str]:
    """PYRO-T1-0001, PYRO-T2-0002, PYRO-T3-0003, PYRO-T1-0004, ...

    Cycling the tier exercises all three shapes DEVICE_ID_PATTERN accepts and
    that the IoT policy pattern PYRO-T?-???? must authorize.
    """
    return [f"PYRO-T{(i % 3) + 1}-{i + 1:04d}" for i in range(count)]


def build_payload(device_id: str, index: int, seq: int, critical: bool) -> dict[str, Any]:
    """One contract-v1 telemetry reading; closed key set, no extra fields."""
    if critical:
        temp_c, rh_pct, smoke_ppm = 55.0, 12.0, 85.0
    else:
        temp_c, rh_pct, smoke_ppm = 16.5, 72.0, 0.1
    return {
        "schema_version": "1.0",
        "device_id": device_id,
        "gateway_id": "GW-01",
        "ts_device": datetime.now(UTC).isoformat(timespec="seconds"),
        "seq": seq,
        "lat": round(BASE_LAT + 0.001 * index, 6),
        "lon": round(BASE_LON - 0.001 * index, 6),
        "elevation_m": 2900.0,
        "temp_c": temp_c,
        "rh_pct": rh_pct,
        "smoke_ppm": smoke_ppm,
        "wind_speed_ms": 2.5,
        "wind_dir_deg": 120.0,
        "battery_pct": 95.0,
        "status": "OK",
    }


def check_contract(payload: dict[str, Any]) -> str:
    """Validate with the approved consumer contract when it is importable.

    Runs only if PYTHONPATH includes src/; otherwise the check is skipped,
    never faked.
    """
    try:
        contract = optional_module("ingest_lambda.contract")
    except ImportError:
        return "skipped (set PYTHONPATH=src to enable)"
    contract.validate_payload(payload)
    return "ok"


# ---------------------------------------------------------------------------
# MQTT
# ---------------------------------------------------------------------------


def connect(config: dict[str, str]) -> Any:
    """Open one mutual-TLS MQTT connection and block until CONNACK."""
    mqtt_connection_builder = optional_module("awsiot.mqtt_connection_builder")

    def on_interrupted(connection: Any, error: Exception, **kwargs: Any) -> None:
        # Fires when the broker drops the connection, e.g. a duplicate client
        # ID or (to be observed) an unauthorized publish.
        print(f"  ! connection interrupted: {type(error).__name__}: {error}")

    def on_resumed(connection: Any, return_code: Any, session_present: bool, **kwargs: Any) -> None:
        print(f"  ! connection resumed: return_code={return_code}")

    connection = mqtt_connection_builder.mtls_from_path(
        endpoint=config["PYROSENSE_IOT_ENDPOINT"],
        cert_filepath=config["PYROSENSE_CERT_PATH"],
        pri_key_filepath=config["PYROSENSE_PRIVATE_KEY_PATH"],
        ca_filepath=config["PYROSENSE_ROOT_CA_PATH"],
        client_id=config["PYROSENSE_CLIENT_ID"],
        # Publish-only client: nothing to keep in a persistent session.
        clean_session=True,
        keep_alive_secs=30,
        on_connection_interrupted=on_interrupted,
        on_connection_resumed=on_resumed,
    )
    connection.connect().result(CONNECT_TIMEOUT_S)
    return connection


def publish_all(connection: Any, config: dict[str, str], args: argparse.Namespace) -> int:
    """Publish every payload at QoS 1, one at a time; return the failure count."""
    mqtt = optional_module("awscrt.mqtt")

    topic_prefix = f"{config['PYROSENSE_TOPIC_BASE']}/{config['PYROSENSE_ENV']}/telemetry"
    # Epoch-based seq: re-running the script never reuses a (device_id, seq)
    # pair, so the future ingest Lambda will not count reruns as duplicates.
    seq_base = int(time.time())
    devices = device_ids(args.devices)
    failures = 0
    latencies_ms: list[float] = []

    for round_index in range(args.messages_per_device):
        for index, device_id in enumerate(devices):
            seq = seq_base + round_index
            topic = f"{topic_prefix}/{device_id}"
            body = json.dumps(
                build_payload(device_id, index, seq, args.critical),
                separators=(",", ":"),
            )
            started = time.monotonic()
            try:
                future, packet_id = connection.publish(
                    topic=topic, payload=body, qos=mqtt.QoS.AT_LEAST_ONCE
                )
                # For QoS 1 the future completes when the PUBACK arrives.
                future.result(PUBACK_TIMEOUT_S)
            # Deliberately broad: awscrt raises varied types and this script's job
            # is to report every failure with its type, never to swallow one.
            except Exception as error:
                failures += 1
                print(f"  FAIL {topic} seq={seq}: {type(error).__name__}: {error}")
            else:
                elapsed = (time.monotonic() - started) * 1000
                latencies_ms.append(elapsed)
                print(f"  OK   {topic} seq={seq} packet_id={packet_id} puback={elapsed:.0f} ms")
            time.sleep(args.interval)

    sent = len(latencies_ms)
    print(f"\nsummary: sent={sent} failed={failures}")
    if latencies_ms:
        average = sum(latencies_ms) / sent
        # A serial QoS 1 publisher cannot beat 1 / PUBACK round trip.
        print(
            f"puback latency: avg={average:.0f} ms max={max(latencies_ms):.0f} ms "
            f"-> serial ceiling ~{1000 / average:.1f} msg/s"
        )
    return failures


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse and validate the command-line options."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--env-file", help="KEY=VALUE file with the PYROSENSE_* settings")
    parser.add_argument("--devices", type=int, default=3, help="simulated sensors (default 3)")
    parser.add_argument("--messages-per-device", type=int, default=2, help="default 2")
    parser.add_argument("--interval", type=float, default=0.5, help="seconds between publishes")
    parser.add_argument("--critical", action="store_true", help="fire-like readings")
    parser.add_argument("--topic-env", help="override {env} in the topic (negative test)")
    parser.add_argument("--client-id", help="override the MQTT client ID (negative test)")
    parser.add_argument("--dry-run", action="store_true", help="print payloads, do not connect")
    args = parser.parse_args(argv)
    if not 1 <= args.devices <= 9999:
        parser.error("--devices must be between 1 and 9999 (4-digit device serial)")
    if args.messages_per_device < 1:
        parser.error("--messages-per-device must be at least 1")
    return args


def main(argv: list[str]) -> int:
    """Run the smoke test; return 0 (OK), 1 (connect/publish failure) or 2 (config error)."""
    args = parse_args(argv)

    if args.dry_run:
        for index, device_id in enumerate(device_ids(args.devices)):
            payload = build_payload(device_id, index, int(time.time()), args.critical)
            print(json.dumps(payload, separators=(",", ":")))
            print(f"  contract check: {check_contract(payload)}")
        return 0

    try:
        config = resolve_config(args)
    except (OSError, ValueError) as error:
        print(f"config error: {error}", file=sys.stderr)
        return 2

    print(f"connecting as client_id={config['PYROSENSE_CLIENT_ID']} ...")
    try:
        connection = connect(config)
    # Deliberately broad: TLS, DNS and auth failures raise different types,
    # and the type name is what tells them apart.
    except Exception as error:
        print(f"CONNECT FAILED: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print("connected\n")

    try:
        failures = publish_all(connection, config, args)
    finally:
        connection.disconnect().result(CONNECT_TIMEOUT_S)
        print("disconnected")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
