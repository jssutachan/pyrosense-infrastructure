"""Tests for cold_store: deterministic Hive key, raw bytes, idempotent put."""

from __future__ import annotations

from typing import Any

import cold_store
from conftest import BUCKET_NAME, make_payload
from contract import validate_payload


def test_object_key_is_hive_partitioned() -> None:
    record = validate_payload(make_payload())
    key = cold_store.object_key(record)
    assert key == "telemetry/dt=2026-09-07/hour=14/PYRO-T1-0042-000000001337.json"


def test_store_writes_raw_bytes(s3_client: Any) -> None:
    record = validate_payload(make_payload())
    raw = '{"raw":"body","as":"received"}'
    key = cold_store.store_raw_copy(s3_client, BUCKET_NAME, record, raw)
    body = s3_client.get_object(Bucket=BUCKET_NAME, Key=key)["Body"].read()
    # Stored byte-for-byte, never re-serialized from the validated record.
    assert body.decode("utf-8") == raw


def test_store_is_idempotent_by_key(s3_client: Any) -> None:
    record = validate_payload(make_payload())
    raw = "{}"
    cold_store.store_raw_copy(s3_client, BUCKET_NAME, record, raw)
    cold_store.store_raw_copy(s3_client, BUCKET_NAME, record, raw)  # same key
    objects = s3_client.list_objects_v2(Bucket=BUCKET_NAME).get("Contents", [])
    assert len(objects) == 1  # duplicate overwrote itself; one object
