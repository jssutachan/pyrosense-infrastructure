"""Hot store writes: DynamoDB single-table with built-in deduplication.

MQTT QoS 1 plus SQS standard queues mean at-least-once delivery: the same
message can arrive twice (broker re-delivery, visibility timeout races,
device reconnects replaying old readings). The conditional write on the
``device_id + seq`` key turns the hot-store insert into the idempotency
guard (ADR-0004): the first delivery wins, replays are detected and
skipped without error.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from decimal import Decimal
from typing import Any

from botocore.exceptions import ClientError

from contract import TelemetryRecord

#: Key layout of the telemetry item family in the single-table design.
TELEMETRY_PK = "DEV#{device_id}"
TELEMETRY_SK = "SEQ#{seq:012d}"


def _decimal(value: float) -> Decimal:
    """Convert a float for DynamoDB, which only accepts Decimal numbers."""
    return Decimal(str(value))


def build_telemetry_item(
    record: TelemetryRecord,
    *,
    retention_days: int,
    now: datetime,
) -> dict[str, Any]:
    """Map a validated record to its DynamoDB item.

    Args:
        record: Validated telemetry message.
        retention_days: Hot retention horizon; sets the ``expires_at``
            TTL attribute (the permanent copy lives in S3).
        now: Ingestion time (injected for testability).

    Returns:
        The item ready for ``put_item``.
    """
    item: dict[str, Any] = {
        "pk": TELEMETRY_PK.format(device_id=record.device_id),
        "sk": TELEMETRY_SK.format(seq=record.seq),
        "device_id": record.device_id,
        "gateway_id": record.gateway_id,
        "tier": record.tier,
        "seq": record.seq,
        "ts_device": record.ts_device.isoformat(),
        "ingested_at": now.isoformat(),
        "lat": _decimal(record.lat),
        "lon": _decimal(record.lon),
        "elevation_m": _decimal(record.elevation_m),
        "temp_c": _decimal(record.temp_c),
        "rh_pct": _decimal(record.rh_pct),
        "smoke_ppm": _decimal(record.smoke_ppm),
        "battery_pct": _decimal(record.battery_pct),
        "status": record.status,
        "expires_at": int((now + timedelta(days=retention_days)).timestamp()),
    }
    # Nullable anemometer fields are stored only when present; DynamoDB
    # queries treat a missing attribute the same as "no anemometer".
    if record.wind_speed_ms is not None:
        item["wind_speed_ms"] = _decimal(record.wind_speed_ms)
    if record.wind_dir_deg is not None:
        item["wind_dir_deg"] = _decimal(record.wind_dir_deg)
    return item


def store_telemetry(
    table: Any,
    record: TelemetryRecord,
    *,
    retention_days: int,
    now: datetime,
) -> bool:
    """Insert a telemetry item if this ``device_id + seq`` is unseen.

    Args:
        table: boto3 DynamoDB ``Table`` resource.
        record: Validated telemetry message.
        retention_days: Hot retention horizon in days.
        now: Ingestion time.

    Returns:
        ``True`` if the item was inserted, ``False`` if an item with the
        same key already existed (duplicate delivery).

    Raises:
        botocore.exceptions.ClientError: On any DynamoDB failure other
            than the conditional check (throttling, access denied...);
            the caller retries via the SQS redrive machinery.
    """
    item = build_telemetry_item(record, retention_days=retention_days, now=now)
    try:
        table.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(pk)",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise
    return True
