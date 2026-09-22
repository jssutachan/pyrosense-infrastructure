"""Tests for alerts: race-free suppression slot and self-contained SNS body."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import alerts
from conftest import make_payload
from contract import validate_payload
from risk import evaluate

NOW = datetime(2026, 9, 7, 14, 30, 0, tzinfo=UTC)
THRESHOLDS = {"smoke_alert_ppm": 5.0, "temp_alert_c": 30.0, "rh_alert_pct": 25.0}


def test_first_acquire_wins(dynamodb_table: Any) -> None:
    assert (
        alerts.try_acquire_alert_slot(
            dynamodb_table, "PYRO-T1-0042", suppression_minutes=30, now=NOW
        )
        is True
    )


def test_second_acquire_within_window_suppressed(dynamodb_table: Any) -> None:
    alerts.try_acquire_alert_slot(dynamodb_table, "PYRO-T1-0042", suppression_minutes=30, now=NOW)
    # Same device, still inside the window → suppressed.
    assert (
        alerts.try_acquire_alert_slot(
            dynamodb_table,
            "PYRO-T1-0042",
            suppression_minutes=30,
            now=NOW + timedelta(minutes=5),
        )
        is False
    )


def test_acquire_again_after_window_succeeds(dynamodb_table: Any) -> None:
    alerts.try_acquire_alert_slot(dynamodb_table, "PYRO-T1-0042", suppression_minutes=30, now=NOW)
    # After the window closes, a new alert may be claimed.
    assert (
        alerts.try_acquire_alert_slot(
            dynamodb_table,
            "PYRO-T1-0042",
            suppression_minutes=30,
            now=NOW + timedelta(minutes=31),
        )
        is True
    )


def test_different_devices_independent(dynamodb_table: Any) -> None:
    assert alerts.try_acquire_alert_slot(
        dynamodb_table, "PYRO-T1-0042", suppression_minutes=30, now=NOW
    )
    assert alerts.try_acquire_alert_slot(
        dynamodb_table, "PYRO-T2-0007", suppression_minutes=30, now=NOW
    )


def test_publish_alert_body_is_self_contained(sns_client: Any, alert_sink: dict[str, Any]) -> None:
    record = validate_payload(make_payload())
    assessment = evaluate(record, **THRESHOLDS)
    alerts.publish_alert(sns_client, alert_sink["topic_arn"], record, assessment)

    messages = alert_sink["received"]()
    assert len(messages) == 1
    body = messages[0]
    assert body["level"] == "CRITICAL"
    assert body["device_id"] == "PYRO-T1-0042"
    assert len(body["reasons"]) == 2
    assert body["location"]["lat"] == 4.6512
    assert body["measurements"]["smoke_ppm"] == 47.3
