"""Shared pytest fixtures: an in-memory AWS stack via moto.

Every effectful test runs against moto's in-memory AWS — no real account,
no credentials, no cost. The stack (DynamoDB table, S3 bucket, SNS topic)
is created fresh per test so cases never leak state into each other.

The ``alert_sink`` fixture wires an SQS queue as an SNS subscription so a
test can *read back* exactly what ``alerts.publish_alert`` published, and
assert on its JSON body. This is how the handler's alert path is verified
end to end without a real inbox.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import boto3
import pytest
from moto import mock_aws

REGION = "us-east-1"
TABLE_NAME = "pyrosense-telemetry-test"
BUCKET_NAME = "pyrosense-cold-test"
TOPIC_NAME = "pyrosense-alerts-test"


@pytest.fixture()
def aws(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Activate moto and set safe fake credentials for the test process."""
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    with mock_aws():
        yield


@pytest.fixture()
def dynamodb_table(aws: None) -> Any:
    """Create the single-table design table and return the Table resource."""
    ddb = boto3.resource("dynamodb", region_name=REGION)
    table = ddb.create_table(
        TableName=TABLE_NAME,
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    table.wait_until_exists()
    return table


@pytest.fixture()
def s3_client(aws: None) -> Any:
    """Create the cold-storage bucket and return the S3 client."""
    client = boto3.client("s3", region_name=REGION)
    client.create_bucket(Bucket=BUCKET_NAME)
    return client


@pytest.fixture()
def sns_client(aws: None) -> Any:
    """Return an SNS client (topics are created by the fixtures that need one)."""
    return boto3.client("sns", region_name=REGION)


@pytest.fixture()
def alert_sink(sns_client: Any) -> dict[str, Any]:
    """SNS topic with an SQS queue subscribed, to capture published alerts.

    Returns a dict with the topic ARN and a ``received()`` helper that
    drains the queue and returns the alert payloads as parsed JSON.
    """
    topic_arn = sns_client.create_topic(Name=TOPIC_NAME)["TopicArn"]
    sqs = boto3.client("sqs", region_name=REGION)
    queue_url = sqs.create_queue(QueueName="alert-capture")["QueueUrl"]
    queue_arn = sqs.get_queue_attributes(QueueUrl=queue_url, AttributeNames=["QueueArn"])[
        "Attributes"
    ]["QueueArn"]
    sns_client.subscribe(
        TopicArn=topic_arn,
        Protocol="sqs",
        Endpoint=queue_arn,
        Attributes={"RawMessageDelivery": "true"},
    )

    def received() -> list[dict[str, Any]]:
        messages = sqs.receive_message(
            QueueUrl=queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=0
        ).get("Messages", [])
        return [json.loads(m["Body"]) for m in messages]

    return {"topic_arn": topic_arn, "received": received}


def make_payload(**overrides: Any) -> dict[str, Any]:
    """A valid contract-v1 payload; override any field for a specific case."""
    payload = {
        "schema_version": "1.0",
        "device_id": "PYRO-T1-0042",
        "gateway_id": "GW-01",
        "ts_device": "2026-09-07T14:23:05Z",
        "seq": 1337,
        "lat": 4.6512,
        "lon": -74.0338,
        "elevation_m": 3150.0,
        "temp_c": 31.4,
        "rh_pct": 18.0,
        "smoke_ppm": 47.3,
        "wind_speed_ms": 5.2,
        "wind_dir_deg": 118.0,
        "battery_pct": 87.0,
        "status": "OK",
    }
    payload.update(overrides)
    return payload


def sqs_event(*bodies: Any) -> dict[str, Any]:
    """Build an SQS event; each body is JSON-encoded unless already a string."""
    records = []
    for i, body in enumerate(bodies):
        encoded = body if isinstance(body, str) else json.dumps(body)
        records.append({"messageId": f"msg-{i}", "body": encoded})
    return {"Records": records}
