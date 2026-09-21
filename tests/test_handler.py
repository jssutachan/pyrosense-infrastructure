"""End-to-end tests for the handler: batch orchestration and error routing."""

from __future__ import annotations

from typing import Any

import pytest

import handler
from conftest import (
    BUCKET_NAME,
    TABLE_NAME,
    make_payload,
    sqs_event,
)


@pytest.fixture()
def wired_handler(
    monkeypatch: pytest.MonkeyPatch,
    dynamodb_table: Any,
    s3_client: Any,
    alert_sink: dict[str, Any],
) -> Any:
    """Point the handler's config at the moto stack and clear its caches."""
    monkeypatch.setenv("ENVIRONMENT", "demo")
    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("BUCKET_NAME", BUCKET_NAME)
    monkeypatch.setenv("ALERT_TOPIC_ARN", alert_sink["topic_arn"])
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
    return handler


def test_valid_critical_message_full_path(
    wired_handler: Any, dynamodb_table: Any, s3_client: Any, alert_sink: dict[str, Any]
) -> None:
    resp = wired_handler.lambda_handler(sqs_event(make_payload()), None)
    assert resp["batchItemFailures"] == []
    # stored in DynamoDB
    item = dynamodb_table.get_item(Key={"pk": "DEV#PYRO-T1-0042", "sk": "SEQ#000000001337"})
    assert "Item" in item
    # archived in S3
    assert s3_client.list_objects_v2(Bucket=BUCKET_NAME).get("KeyCount", 0) == 1
    # alert published
    assert len(alert_sink["received"]()) == 1


def test_duplicate_is_skipped_no_second_alert(
    wired_handler: Any, alert_sink: dict[str, Any]
) -> None:
    wired_handler.lambda_handler(sqs_event(make_payload()), None)
    alert_sink["received"]()  # drain the first alert
    resp = wired_handler.lambda_handler(sqs_event(make_payload()), None)
    assert resp["batchItemFailures"] == []
    # suppression + dedup: no new alert on the replay
    assert alert_sink["received"]() == []


def test_invalid_payload_routed_to_failures(wired_handler: Any) -> None:
    resp = wired_handler.lambda_handler(sqs_event(make_payload(status="BAD")), None)
    assert resp["batchItemFailures"] == [{"itemIdentifier": "msg-0"}]


def test_broken_json_routed_to_failures(wired_handler: Any) -> None:
    resp = wired_handler.lambda_handler(sqs_event("not-json{{{"), None)
    assert resp["batchItemFailures"] == [{"itemIdentifier": "msg-0"}]


def test_mixed_batch_only_bad_one_fails(wired_handler: Any, dynamodb_table: Any) -> None:
    event = sqs_event(
        make_payload(device_id="PYRO-T2-0007", seq=500),  # valid, new
        "broken{{{",  # permanent failure
        make_payload(),  # valid, new
    )
    resp = wired_handler.lambda_handler(event, None)
    assert resp["batchItemFailures"] == [{"itemIdentifier": "msg-1"}]


def test_two_criticals_same_device_one_alert(
    wired_handler: Any, alert_sink: dict[str, Any]
) -> None:
    # Same device, different seq, same batch: both stored, one alert.
    event = sqs_event(make_payload(seq=20), make_payload(seq=21))
    resp = wired_handler.lambda_handler(event, None)
    assert resp["batchItemFailures"] == []
    assert len(alert_sink["received"]()) == 1


def test_empty_event_is_safe(wired_handler: Any) -> None:
    resp = wired_handler.lambda_handler({"Records": []}, None)
    assert resp == {"batchItemFailures": []}


def test_emf_emitted_on_stdout(wired_handler: Any, capsys: pytest.CaptureFixture[str]) -> None:
    import json

    wired_handler.lambda_handler(sqs_event(make_payload()), None)
    stdout_lines = [line for line in capsys.readouterr().out.splitlines() if line.strip()]
    # Exactly one EMF document per invocation, on stdout.
    assert len(stdout_lines) == 1
    assert "_aws" in json.loads(stdout_lines[0])
