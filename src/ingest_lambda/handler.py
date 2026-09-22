"""Entry point of the PyroSense ingest Lambda.

Consumes telemetry batches from SQS and, per message:

1. Validates the frozen contract v1 (:mod:`contract`).
2. Classifies fire risk (:mod:`risk`) — the decision the sensor never makes.
3. Archives the raw body in S3 (:mod:`cold_store`, idempotent by key).
4. On CRITICAL risk, publishes an alert guarded by the per-device
   suppression window (:mod:`alerts`).
5. Inserts the hot item in DynamoDB; the conditional write doubles as
   the at-least-once deduplication guard (:mod:`persistence`).

Every step is idempotent or condition-guarded, so a crash mid-message is
safely replayed by SQS. Failures are reported per message via partial
batch responses (``ReportBatchItemFailures``): contract violations are
permanent and land in the DLQ after ``maxReceiveCount`` attempts, which
is exactly where a broken producer should surface.

Logs are emitted as structured JSON on **stderr** (:mod:`structured_logging`),
carrying whitelisted context fields (``device_id``, ``seq``, ``message_id``,
``errors``, ``reasons``) so CloudWatch Logs Insights can query them directly.
EMF metric documents stay on **stdout** (:mod:`metrics`): two channels, no
collisions.
"""

from __future__ import annotations

import functools
import json
import logging
from datetime import UTC, datetime
from typing import Any

import boto3

import alerts
import cold_store
import metrics
import persistence
import structured_logging
from config import Settings
from contract import ContractViolationError, validate_payload
from risk import RiskLevel, evaluate

logger = logging.getLogger(__name__)


@functools.lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Load and cache the function configuration.

    Routes the root logger through the JSON formatter (:mod:`structured_logging`)
    once, at cold start. ``configure`` sets the level itself, so there is no
    separate ``setLevel`` call.
    """
    settings = Settings.from_env()
    structured_logging.configure(settings.log_level)
    return settings


@functools.lru_cache(maxsize=1)
def get_table() -> Any:
    """Cached DynamoDB Table resource."""
    return boto3.resource("dynamodb").Table(get_settings().table_name)


@functools.lru_cache(maxsize=1)
def get_s3() -> Any:
    """Cached S3 client."""
    return boto3.client("s3")


@functools.lru_cache(maxsize=1)
def get_sns() -> Any:
    """Cached SNS client."""
    return boto3.client("sns")


def _process_message(body: str, settings: Settings, now: datetime) -> dict[str, int]:
    """Process one SQS message body end to end.

    Args:
        body: Raw message body (the JSON published by the device).
        settings: Function configuration.
        now: Ingestion time for this batch.

    Returns:
        Outcome counters for this message (keys match the EMF metrics).

    Raises:
        ContractViolationError: If the payload breaks contract v1 (permanent
            failure — the message must redrive to the DLQ).
        Exception: Any AWS failure (transient — the message is retried).
    """
    counts = {
        "MessagesStored": 0,
        "DuplicatesSkipped": 0,
        "AlertsPublished": 0,
        "AlertsSuppressed": 0,
    }

    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise ContractViolationError([f"body is not valid JSON: {exc}"]) from exc

    record = validate_payload(payload)
    assessment = evaluate(
        record,
        smoke_alert_ppm=settings.smoke_alert_ppm,
        temp_alert_c=settings.temp_alert_c,
        rh_alert_pct=settings.rh_alert_pct,
    )

    cold_store.store_raw_copy(get_s3(), settings.bucket_name, record, body)

    if assessment.level is RiskLevel.CRITICAL:
        if alerts.try_acquire_alert_slot(
            get_table(),
            record.device_id,
            suppression_minutes=settings.alert_suppression_minutes,
            now=now,
        ):
            alerts.publish_alert(get_sns(), settings.alert_topic_arn, record, assessment)
            counts["AlertsPublished"] = 1
            logger.warning(
                "CRITICAL risk at %s (seq=%d): %s",
                record.device_id,
                record.seq,
                "; ".join(assessment.reasons),
                extra={
                    "device_id": record.device_id,
                    "seq": record.seq,
                    "reasons": list(assessment.reasons),
                },
            )
        else:
            counts["AlertsSuppressed"] = 1

    inserted = persistence.store_telemetry(
        get_table(),
        record,
        retention_days=settings.hot_retention_days,
        now=now,
    )
    if inserted:
        counts["MessagesStored"] = 1
    else:
        counts["DuplicatesSkipped"] = 1
        logger.info(
            "Duplicate delivery skipped: %s seq=%d",
            record.device_id,
            record.seq,
            extra={"device_id": record.device_id, "seq": record.seq},
        )

    return counts


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Process an SQS batch with partial failure reporting.

    Args:
        event: SQS event (``Records`` list).
        context: Lambda context (unused).

    Returns:
        The partial batch response expected by the event source mapping:
        ``{"batchItemFailures": [{"itemIdentifier": <messageId>}, ...]}``.
    """
    settings = get_settings()
    now = datetime.now(UTC)

    failures: list[dict[str, str]] = []
    totals = {
        "MessagesStored": 0,
        "DuplicatesSkipped": 0,
        "InvalidPayloads": 0,
        "AlertsPublished": 0,
        "AlertsSuppressed": 0,
    }

    for sqs_record in event.get("Records", []):
        message_id = sqs_record["messageId"]
        try:
            outcome = _process_message(sqs_record["body"], settings, now)
        except ContractViolationError as exc:
            # Permanent: no retry can fix a broken payload. Failing the
            # item routes it to the DLQ, preserving the evidence.
            totals["InvalidPayloads"] += 1
            failures.append({"itemIdentifier": message_id})
            logger.error(
                "Contract violation (message %s): %s",
                message_id,
                exc.errors,
                extra={"message_id": message_id, "errors": exc.errors},
            )
        except Exception:
            # Transient (throttling, permissions, networking): retry.
            failures.append({"itemIdentifier": message_id})
            logger.exception(
                "Processing failed (message %s); will retry",
                message_id,
                extra={"message_id": message_id},
            )
        else:
            for key, value in outcome.items():
                totals[key] += value

    metrics.emit_counts(settings.metrics_namespace, settings.environment, totals)
    return {"batchItemFailures": failures}
