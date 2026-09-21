"""Cold store writes: the raw, untouched payload archived in S3.

The cold copy is the audit trail and the analytics source of truth, so
the *original* message body is stored byte-for-byte (never a re-serialized
version that could mask producer bugs). Keys are Hive-partitioned by
device timestamp so Athena/Glue can query the history without listing
the whole bucket.

Writes are idempotent by construction: a redelivered message maps to the
same key and overwrites itself with identical content.
"""

from __future__ import annotations

from datetime import UTC
from typing import Any

from contract import TelemetryRecord

#: Hive-style partition layout under the telemetry/ prefix.
KEY_TEMPLATE = "telemetry/dt={date}/hour={hour:02d}/{device_id}-{seq:012d}.json"


def object_key(record: TelemetryRecord) -> str:
    """Compute the deterministic S3 key for a record.

    Args:
        record: Validated telemetry message.

    Returns:
        The bucket-relative object key.
    """
    ts_utc = record.ts_device.astimezone(UTC)
    return KEY_TEMPLATE.format(
        date=ts_utc.strftime("%Y-%m-%d"),
        hour=ts_utc.hour,
        device_id=record.device_id,
        seq=record.seq,
    )


def store_raw_copy(
    s3_client: Any,
    bucket: str,
    record: TelemetryRecord,
    raw_body: str,
) -> str:
    """Archive the original message body in the cold bucket.

    Args:
        s3_client: boto3 S3 client.
        bucket: Cold-storage bucket name.
        record: Validated telemetry message (drives the key layout).
        raw_body: The message body exactly as received from SQS.

    Returns:
        The object key that was written.
    """
    key = object_key(record)
    s3_client.put_object(
        Bucket=bucket,
        Key=key,
        Body=raw_body.encode("utf-8"),
        ContentType="application/json",
    )
    return key
