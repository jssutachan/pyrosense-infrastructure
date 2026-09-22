"""Transient-vs-permanent error handling: the classification that decides retries."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

import pytest
from botocore.exceptions import ClientError

import alerts
import persistence
from conftest import make_payload
from contract import validate_payload

NOW = datetime(2026, 9, 7, 14, 30, 0, tzinfo=UTC)


class _RaisingTable:
    """A fake DynamoDB Table whose put_item raises a chosen ClientError."""

    def __init__(self, code: str) -> None:
        self._code = code

    def put_item(self, **_: Any) -> None:
        raise ClientError({"Error": {"Code": self._code, "Message": "boom"}}, "PutItem")


def test_persistence_reraises_non_conditional_error() -> None:
    # Throttling is transient: it must propagate so SQS retries the message,
    # never be swallowed as a "duplicate".
    record = validate_payload(make_payload())
    table = _RaisingTable("ProvisionedThroughputExceededException")
    with pytest.raises(ClientError):
        persistence.store_telemetry(table, record, retention_days=7, now=NOW)


def test_alerts_reraises_non_conditional_error() -> None:
    table = _RaisingTable("ProvisionedThroughputExceededException")
    with pytest.raises(ClientError):
        alerts.try_acquire_alert_slot(table, "PYRO-T1-0042", suppression_minutes=30, now=NOW)


def test_handler_transient_failure_is_retried(monkeypatch: pytest.MonkeyPatch) -> None:
    # A non-contract error (e.g. AWS failure) must land in batchItemFailures
    # WITHOUT being counted as an invalid payload.
    import handler
    from conftest import BUCKET_NAME, TABLE_NAME, sqs_event

    monkeypatch.setenv("ENVIRONMENT", "demo")
    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("BUCKET_NAME", BUCKET_NAME)
    monkeypatch.setenv("ALERT_TOPIC_ARN", "arn:aws:sns:us-east-1:000000000000:x")
    monkeypatch.setenv("SMOKE_ALERT_PPM", "5.0")
    monkeypatch.setenv("TEMP_ALERT_C", "30.0")
    monkeypatch.setenv("RH_ALERT_PCT", "25.0")
    monkeypatch.setenv("HOT_RETENTION_DAYS", "7")
    monkeypatch.setenv("ALERT_SUPPRESSION_MINUTES", "30")
    monkeypatch.setenv("METRICS_NAMESPACE", "PyroSense/Ingest")
    monkeypatch.setenv("LOG_LEVEL", "INFO")
    for cached in (
        handler.get_settings,
        handler.get_table,
        handler.get_s3,
        handler.get_sns,
    ):
        cached.cache_clear()

    def boom(*_: Any, **__: Any) -> None:
        raise RuntimeError("S3 unavailable")

    monkeypatch.setattr(handler.cold_store, "store_raw_copy", boom)

    resp = handler.lambda_handler(sqs_event(make_payload()), None)
    assert resp["batchItemFailures"] == [{"itemIdentifier": "msg-0"}]
