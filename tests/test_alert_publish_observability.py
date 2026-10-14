"""Observability contracts of the ingest handler (ADR-0015 D2, ADR-0021).

modules/observability alarms on two things this code produces and Terraform
cannot check: the ``AlertPublishFailures`` EMF counter and the
``Processing failed`` prefix of the transient-failure log line, counted by a
CloudWatch metric filter. These tests pin both on the *rendered* output (the
EMF document on stdout and the JSON log line), which is what CloudWatch sees.

Self-contained on purpose: AWS clients and the persistence layer are
replaced with mocks, so each test exercises exactly one failure path of
``lambda_handler`` and nothing else.
"""

from __future__ import annotations

import json
import logging
from datetime import UTC, datetime
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

import pytest
from botocore.exceptions import ClientError

import alerts
import cold_store
import handler
import persistence
import structured_logging
from risk import RiskLevel

#: Every counter the alarms and the dashboard read. A rename here must be a
#: deliberate change to modules/observability too.
EXPECTED_EMF_METRICS = {
    "MessagesStored",
    "DuplicatesSkipped",
    "InvalidPayloads",
    "AlertsPublished",
    "AlertsSuppressed",
    "AlertPublishFailures",
}

DEVICE_ID = "PYRO-T1-0001"
SEQ = 42
MESSAGE_ID = "msg-0001"


def _critical_body() -> str:
    """Return a contract-v1 payload whose smoke reading is CRITICAL."""
    return json.dumps(
        {
            "schema_version": "1.0",
            "device_id": DEVICE_ID,
            "gateway_id": "GW-01",
            "ts_device": "2026-10-08T07:00:00+00:00",
            "seq": SEQ,
            "lat": 4.6,
            "lon": -74.05,
            "elevation_m": 2800.0,
            "temp_c": 22.0,
            "rh_pct": 60.0,
            "smoke_ppm": 50.0,
            "wind_speed_ms": 2.0,
            "wind_dir_deg": 180.0,
            "battery_pct": 90.0,
            "status": "OK",
        }
    )


def _event() -> dict[str, Any]:
    """Return an SQS event with one CRITICAL message."""
    return {"Records": [{"messageId": MESSAGE_ID, "body": _critical_body()}]}


@pytest.fixture
def isolated_handler(monkeypatch: pytest.MonkeyPatch) -> SimpleNamespace:
    """Isolate lambda_handler from AWS and return the mocks a test may drive.

    Settings are a plain namespace with the attributes the handler reads, so
    the test does not depend on environment variables. The slot claim always
    succeeds and the hot write always inserts: only the step under test fails.
    """
    settings = SimpleNamespace(
        smoke_alert_ppm=5.0,
        temp_alert_c=30.0,
        rh_alert_pct=25.0,
        bucket_name="cold-bucket",
        alert_topic_arn="arn:aws:sns:us-east-1:123456789012:fire-alerts",
        alert_suppression_minutes=30,
        hot_retention_days=19,
        metrics_namespace="PyroSense/Ingest",
        environment="test",
    )
    mocks = SimpleNamespace(sns=MagicMock(), store_raw_copy=MagicMock())
    monkeypatch.setattr(handler, "get_settings", lambda: settings)
    monkeypatch.setattr(handler, "get_s3", MagicMock)
    monkeypatch.setattr(handler, "get_table", MagicMock)
    monkeypatch.setattr(handler, "get_sns", lambda: mocks.sns)
    monkeypatch.setattr(cold_store, "store_raw_copy", mocks.store_raw_copy)
    monkeypatch.setattr(alerts, "try_acquire_alert_slot", MagicMock(return_value=True))
    monkeypatch.setattr(persistence, "store_telemetry", MagicMock(return_value=True))
    return mocks


def _emf(capsys: pytest.CaptureFixture[str]) -> dict[str, Any]:
    """Parse the single EMF document the handler printed on stdout."""
    lines = [line for line in capsys.readouterr().out.splitlines() if line.strip()]
    assert len(lines) == 1
    document: dict[str, Any] = json.loads(lines[0])
    return document


def _rendered(record: logging.LogRecord) -> dict[str, Any]:
    """Render a record exactly as the deployed function writes it."""
    rendered: dict[str, Any] = json.loads(structured_logging.JsonFormatter().format(record))
    return rendered


def test_failed_publish_is_counted_logged_critical_and_retried(
    isolated_handler: SimpleNamespace,
    capsys: pytest.CaptureFixture[str],
    caplog: pytest.LogCaptureFixture,
) -> None:
    """A publish failure after the slot claim is counted, CRITICAL and retried."""
    isolated_handler.sns.publish.side_effect = ClientError(
        {"Error": {"Code": "AuthorizationError", "Message": "denied"}}, "Publish"
    )

    with caplog.at_level(logging.INFO):
        response = handler.lambda_handler(_event(), None)

    assert response == {"batchItemFailures": [{"itemIdentifier": MESSAGE_ID}]}

    emf = _emf(capsys)
    assert emf["AlertPublishFailures"] == 1
    assert emf["AlertsPublished"] == 0

    critical = [r for r in caplog.records if r.levelno == logging.CRITICAL]
    assert len(critical) == 1
    line = _rendered(critical[0])
    assert line["level"] == "CRITICAL"
    assert line["message"].startswith(handler.TRANSIENT_FAILURE_LOG_PREFIX)
    assert line["device_id"] == DEVICE_ID
    assert line["seq"] == SEQ
    assert line["message_id"] == MESSAGE_ID
    assert "AuthorizationError" in line["exception"]


def test_generic_transient_failure_keeps_the_metric_filter_prefix(
    isolated_handler: SimpleNamespace,
    capsys: pytest.CaptureFixture[str],
    caplog: pytest.LogCaptureFixture,
) -> None:
    """A non-alert dependency failure logs the prefix and counts no lost alert."""
    isolated_handler.store_raw_copy.side_effect = ClientError(
        {"Error": {"Code": "AccessDenied", "Message": "denied"}}, "PutObject"
    )

    with caplog.at_level(logging.INFO):
        response = handler.lambda_handler(_event(), None)

    assert response == {"batchItemFailures": [{"itemIdentifier": MESSAGE_ID}]}
    assert _emf(capsys)["AlertPublishFailures"] == 0
    isolated_handler.sns.publish.assert_not_called()

    errors = [r for r in caplog.records if r.levelno == logging.ERROR]
    assert len(errors) == 1
    line = _rendered(errors[0])
    assert line["message"].startswith("Processing failed")
    assert line["message_id"] == MESSAGE_ID


def test_emf_document_carries_exactly_the_observed_metrics(
    isolated_handler: SimpleNamespace,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The happy path emits all six counters, zeros included."""
    response = handler.lambda_handler(_event(), None)

    assert response == {"batchItemFailures": []}
    emf = _emf(capsys)
    declared = {m["Name"] for m in emf["_aws"]["CloudWatchMetrics"][0]["Metrics"]}
    assert declared == EXPECTED_EMF_METRICS
    assert emf["_aws"]["CloudWatchMetrics"][0]["Dimensions"] == [["Environment"]]
    assert emf["AlertsPublished"] == 1
    assert emf["AlertPublishFailures"] == 0
    isolated_handler.sns.publish.assert_called_once()


def test_subject_is_truncated_below_the_sns_limit() -> None:
    """SNS requires a Subject of less than 100 characters."""
    sns = MagicMock()
    record = SimpleNamespace(
        device_id="X" * 200,
        gateway_id="GW-01",
        tier="T1",
        ts_device=datetime(2026, 10, 8, 7, 0, tzinfo=UTC),
        lat=4.6,
        lon=-74.05,
        elevation_m=2800.0,
        temp_c=22.0,
        rh_pct=60.0,
        smoke_ppm=50.0,
        wind_speed_ms=2.0,
        wind_dir_deg=180.0,
        status="OK",
    )
    assessment = SimpleNamespace(level=RiskLevel.CRITICAL, reasons=("smoke",))

    alerts.publish_alert(sns, "arn:aws:sns:us-east-1:123456789012:t", record, assessment)

    subject = sns.publish.call_args.kwargs["Subject"]
    assert len(subject) == 99
    assert len(subject) < 100
