"""Tests for persistence: conditional-write dedup, Decimal coercion, TTL."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any

import persistence
from conftest import make_payload
from contract import validate_payload

NOW = datetime(2026, 9, 7, 14, 30, 0, tzinfo=UTC)


def test_store_new_item_returns_true(dynamodb_table: Any) -> None:
    record = validate_payload(make_payload())
    inserted = persistence.store_telemetry(dynamodb_table, record, retention_days=7, now=NOW)
    assert inserted is True
    item = dynamodb_table.get_item(Key={"pk": "DEV#PYRO-T1-0042", "sk": "SEQ#000000001337"})["Item"]
    assert item["device_id"] == "PYRO-T1-0042"
    assert item["tier"] == "T1"


def test_duplicate_returns_false(dynamodb_table: Any) -> None:
    record = validate_payload(make_payload())
    assert persistence.store_telemetry(dynamodb_table, record, retention_days=7, now=NOW)
    # Same device_id + seq → conditional write fails → False, no error.
    second = persistence.store_telemetry(dynamodb_table, record, retention_days=7, now=NOW)
    assert second is False


def test_floats_stored_as_decimal(dynamodb_table: Any) -> None:
    record = validate_payload(make_payload())
    persistence.store_telemetry(dynamodb_table, record, retention_days=7, now=NOW)
    item = dynamodb_table.get_item(Key={"pk": "DEV#PYRO-T1-0042", "sk": "SEQ#000000001337"})["Item"]
    assert isinstance(item["temp_c"], Decimal)


def test_ttl_expires_at_is_set(dynamodb_table: Any) -> None:
    record = validate_payload(make_payload())
    persistence.store_telemetry(dynamodb_table, record, retention_days=7, now=NOW)
    item = dynamodb_table.get_item(Key={"pk": "DEV#PYRO-T1-0042", "sk": "SEQ#000000001337"})["Item"]
    expected = int((NOW + timedelta(days=7)).timestamp())
    assert int(item["expires_at"]) == expected


def test_null_wind_fields_omitted(dynamodb_table: Any) -> None:
    record = validate_payload(make_payload(wind_speed_ms=None, wind_dir_deg=None))
    persistence.store_telemetry(dynamodb_table, record, retention_days=7, now=NOW)
    item = dynamodb_table.get_item(Key={"pk": "DEV#PYRO-T1-0042", "sk": "SEQ#000000001337"})["Item"]
    assert "wind_speed_ms" not in item
    assert "wind_dir_deg" not in item


def test_build_item_padding() -> None:
    record = validate_payload(make_payload(seq=42))
    item = persistence.build_telemetry_item(record, retention_days=7, now=NOW)
    assert item["sk"] == "SEQ#000000000042"  # zero-padded to 12 digits
