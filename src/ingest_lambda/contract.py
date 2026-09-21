"""Validation of the frozen telemetry contract v1.

Mirrors ``docs/payload-schema-v1.json`` (the schema exported by the
simulator): required keys, closed key set, value ranges, identifier
patterns and the device-health enum. The sensor never decides whether
there is a fire — it reports raw measurements; the risk decision lives
in :mod:`risk`.

The consumer re-validates instead of trusting the producer because the
queue boundary is exactly where integration bugs (and spoofed messages)
surface.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from datetime import UTC, datetime

SCHEMA_VERSION = "1.0"

# Full-string patterns used with ``fullmatch`` so no trailing newline can
# slip past (``$`` also matches just before a final ``\n``).
DEVICE_ID_PATTERN = re.compile(r"PYRO-T[123]-\d{4}")
GATEWAY_ID_PATTERN = re.compile(r"GW-\d{2,}")

DEVICE_STATUSES = frozenset({"OK", "DEGRADED", "LOW_BATTERY"})

REQUIRED_KEYS = frozenset(
    {
        "device_id",
        "gateway_id",
        "ts_device",
        "seq",
        "lat",
        "lon",
        "elevation_m",
        "temp_c",
        "rh_pct",
        "smoke_ppm",
        "wind_speed_ms",
        "wind_dir_deg",
        "battery_pct",
        "status",
    }
)

# schema_version is optional on the wire (it has a default) but no other
# key may appear: the contract forbids unknown fields in both directions.
ALLOWED_KEYS = REQUIRED_KEYS | {"schema_version"}


class ContractViolationError(ValueError):
    """A payload that does not conform to telemetry contract v1.

    Attributes:
        errors: Human-readable description of every violation found.
    """

    def __init__(self, errors: list[str]) -> None:
        """Join all violations into the exception message."""
        super().__init__("; ".join(errors))
        self.errors = errors


@dataclass(frozen=True)
class TelemetryRecord:
    """A validated, immutable telemetry message.

    Field semantics are defined by the data contract; see
    ``docs/payload-schema-v1.json``.
    """

    device_id: str
    gateway_id: str
    ts_device: datetime
    seq: int
    lat: float
    lon: float
    elevation_m: float
    temp_c: float
    rh_pct: float
    smoke_ppm: float
    wind_speed_ms: float | None
    wind_dir_deg: float | None
    battery_pct: float
    status: str

    @property
    def tier(self) -> str:
        """Device tier (``T1``/``T2``/``T3``) embedded in the device id."""
        return self.device_id.split("-")[1]


def _check_number(
    errors: list[str],
    data: dict[str, object],
    key: str,
    minimum: float | None = None,
    maximum: float | None = None,
    nullable: bool = False,
) -> float | None:
    """Validate one numeric field, appending problems to ``errors``."""
    value = data[key]
    if value is None:
        if not nullable:
            errors.append(f"{key}: must not be null")
        return None
    # bool is a subclass of int and must not pass as a measurement.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        errors.append(f"{key}: expected a number, got {type(value).__name__}")
        return None
    number = float(value)
    # NaN/Infinity are valid Python floats and silently defeat range
    # checks (nan compares False against everything; inf passes any
    # field without an upper bound). Reject them explicitly.
    if not math.isfinite(number):
        errors.append(f"{key}: must be a finite number, got {value!r}")
        return None
    if minimum is not None and number < minimum:
        errors.append(f"{key}: {number} is below the minimum {minimum}")
    if maximum is not None and number > maximum:
        errors.append(f"{key}: {number} is above the maximum {maximum}")
    return number


def _parse_ts_device(errors: list[str], raw: object) -> datetime:
    """Parse the device timestamp, requiring an explicit timezone."""
    fallback = datetime.fromtimestamp(0, tz=UTC)
    if not isinstance(raw, str):
        errors.append(f"ts_device: expected an ISO-8601 string, got {type(raw).__name__}")
        return fallback
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        errors.append(f"ts_device: not a valid ISO-8601 timestamp: {raw!r}")
        return fallback
    if parsed.tzinfo is None:
        errors.append("ts_device: timestamp must be timezone-aware (UTC)")
        return fallback
    return parsed.astimezone(UTC)


def validate_payload(data: object) -> TelemetryRecord:
    """Validate a decoded JSON payload against contract v1.

    Args:
        data: The decoded message body (expected to be a JSON object).

    Returns:
        The validated telemetry record.

    Raises:
        ContractViolationError: If the payload violates the contract in any
            way. All violations are collected before raising so a single
            log line explains the full mismatch.
    """
    if not isinstance(data, dict):
        raise ContractViolationError(["payload: expected a JSON object"])

    errors: list[str] = []

    unknown = sorted(set(data) - ALLOWED_KEYS)
    if unknown:
        errors.append(f"unknown fields not allowed by contract v1: {', '.join(unknown)}")

    missing = sorted(REQUIRED_KEYS - set(data))
    if missing:
        errors.append(f"missing required fields: {', '.join(missing)}")
        raise ContractViolationError(errors)

    version = data.get("schema_version", SCHEMA_VERSION)
    if version != SCHEMA_VERSION:
        errors.append(f"schema_version: expected {SCHEMA_VERSION!r}, got {version!r}")

    device_id = data["device_id"]
    if not isinstance(device_id, str) or not DEVICE_ID_PATTERN.fullmatch(device_id):
        errors.append(f"device_id: {device_id!r} does not match {DEVICE_ID_PATTERN.pattern}")

    gateway_id = data["gateway_id"]
    if not isinstance(gateway_id, str) or not GATEWAY_ID_PATTERN.fullmatch(gateway_id):
        errors.append(f"gateway_id: {gateway_id!r} does not match {GATEWAY_ID_PATTERN.pattern}")

    ts_device = _parse_ts_device(errors, data["ts_device"])

    seq = data["seq"]
    if isinstance(seq, bool) or not isinstance(seq, int) or seq < 0:
        errors.append(f"seq: expected a non-negative integer, got {seq!r}")
        seq = 0

    lat = _check_number(errors, data, "lat", -90.0, 90.0)
    lon = _check_number(errors, data, "lon", -180.0, 180.0)
    elevation_m = _check_number(errors, data, "elevation_m")
    temp_c = _check_number(errors, data, "temp_c", -20.0, 80.0)
    rh_pct = _check_number(errors, data, "rh_pct", 0.0, 100.0)
    smoke_ppm = _check_number(errors, data, "smoke_ppm", 0.0)
    wind_speed_ms = _check_number(errors, data, "wind_speed_ms", 0.0, nullable=True)
    wind_dir_deg = _check_number(errors, data, "wind_dir_deg", 0.0, 360.0, nullable=True)
    battery_pct = _check_number(errors, data, "battery_pct", 0.0, 100.0)

    status = data["status"]
    if not isinstance(status, str) or status not in DEVICE_STATUSES:
        errors.append(f"status: {status!r} is not one of {sorted(DEVICE_STATUSES)}")

    if errors:
        raise ContractViolationError(errors)

    return TelemetryRecord(
        device_id=str(device_id),
        gateway_id=str(gateway_id),
        ts_device=ts_device,
        seq=int(seq),
        lat=float(lat),  # type: ignore[arg-type]
        lon=float(lon),  # type: ignore[arg-type]
        elevation_m=float(elevation_m),  # type: ignore[arg-type]
        temp_c=float(temp_c),  # type: ignore[arg-type]
        rh_pct=float(rh_pct),  # type: ignore[arg-type]
        smoke_ppm=float(smoke_ppm),  # type: ignore[arg-type]
        wind_speed_ms=wind_speed_ms,
        wind_dir_deg=wind_dir_deg,
        battery_pct=float(battery_pct),  # type: ignore[arg-type]
        status=str(status),
    )
