"""Fire-risk alert publication with per-device suppression.

A burning sensor keeps reporting critical smoke every few seconds; without
suppression that becomes hundreds of identical emails. A conditional write
on an alert-state item in the same DynamoDB table implements a per-device
suppression window that is race-free across concurrent Lambda executions:
only the invocation that wins the conditional write may publish.

Known trade-off (claim-before-publish): the slot is claimed *before* the
SNS publish. If the publish then fails, the slot is already taken, so the
retried message finds the window closed and that single alert is dropped
for the suppression window. This is a deliberate choice: claiming *after*
publishing would instead duplicate emails whenever two executions race.
For an early-warning MVP, dropping at most one alert on a rare SNS failure
is preferable to email storms; a two-phase claim (short reservation +
confirm-after-publish) is the production-hardening path if this ever
matters. See the open ADR on alert delivery semantics.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta
from typing import Any

from botocore.exceptions import ClientError

from contract import TelemetryRecord
from risk import RiskAssessment

#: Key layout of the alert-state item family in the single-table design.
ALERT_PK = "ALERT#{device_id}"
ALERT_SK = "STATE"

#: SNS subjects are limited to 100 characters.
_MAX_SUBJECT = 100


def try_acquire_alert_slot(
    table: Any,
    device_id: str,
    *,
    suppression_minutes: int,
    now: datetime,
) -> bool:
    """Attempt to claim the right to alert for this device.

    Args:
        table: boto3 DynamoDB ``Table`` resource.
        device_id: Device the alert refers to.
        suppression_minutes: Window during which further alerts for the
            same device are suppressed.
        now: Current time (injected for testability).

    Returns:
        ``True`` if this invocation owns the alert slot and must
        publish; ``False`` if a previous alert is still suppressing.

    Raises:
        botocore.exceptions.ClientError: On any DynamoDB failure other
            than the conditional check.
    """
    suppress_until = int((now + timedelta(minutes=suppression_minutes)).timestamp())
    try:
        table.put_item(
            Item={
                "pk": ALERT_PK.format(device_id=device_id),
                "sk": ALERT_SK,
                "suppress_until": suppress_until,
                # TTL cleanup well after the window closes.
                "expires_at": int((now + timedelta(days=1)).timestamp()),
            },
            ConditionExpression="attribute_not_exists(pk) OR suppress_until < :now",
            ExpressionAttributeValues={":now": int(now.timestamp())},
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise
    return True


def publish_alert(
    sns_client: Any,
    topic_arn: str,
    record: TelemetryRecord,
    assessment: RiskAssessment,
) -> None:
    """Publish one fire-risk alert to SNS.

    The message is a self-contained JSON document: an operator (or a
    downstream consumer) gets location, measurements and the reasons the
    rules fired without having to query anything else.

    Args:
        sns_client: boto3 SNS client.
        topic_arn: Fire-risk topic ARN.
        record: The telemetry record that triggered the alert.
        assessment: The risk assessment (level and reasons).
    """
    subject = f"[PyroSense {assessment.level.value}] fire risk at {record.device_id}"
    message = {
        "level": assessment.level.value,
        "reasons": list(assessment.reasons),
        "device_id": record.device_id,
        "gateway_id": record.gateway_id,
        "tier": record.tier,
        "ts_device": record.ts_device.isoformat(),
        "location": {
            "lat": record.lat,
            "lon": record.lon,
            "elevation_m": record.elevation_m,
        },
        "measurements": {
            "temp_c": record.temp_c,
            "rh_pct": record.rh_pct,
            "smoke_ppm": record.smoke_ppm,
            "wind_speed_ms": record.wind_speed_ms,
            "wind_dir_deg": record.wind_dir_deg,
        },
        "device_status": record.status,
    }
    sns_client.publish(
        TopicArn=topic_arn,
        Subject=subject[:_MAX_SUBJECT],
        Message=json.dumps(message),
    )
