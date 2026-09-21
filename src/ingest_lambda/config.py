"""Runtime configuration for the ingest Lambda.

Every knob comes from environment variables injected by Terraform; the
code contains no endpoint, ARN or threshold literals. Missing or
malformed required variables fail fast at cold start with an explicit,
variable-named error.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Immutable snapshot of the function configuration.

    Attributes:
        environment: Deployment environment (``demo`` or ``prod``); used
            as the EMF metrics dimension.
        table_name: DynamoDB table holding hot telemetry and alert state.
        bucket_name: S3 bucket receiving the raw cold copy.
        alert_topic_arn: SNS topic for fire-risk alerts.
        smoke_alert_ppm: Smoke concentration classified as CRITICAL.
        temp_alert_c: Temperature that, with low humidity, is ELEVATED.
        rh_alert_pct: Relative humidity that, with high temperature, is
            ELEVATED.
        hot_retention_days: Days a telemetry item lives in DynamoDB
            before TTL expiry.
        alert_suppression_minutes: Minimum spacing between alerts for
            the same device.
        metrics_namespace: CloudWatch namespace for EMF metrics.
        log_level: Logging level name (e.g. ``INFO``).
    """

    environment: str
    table_name: str
    bucket_name: str
    alert_topic_arn: str
    smoke_alert_ppm: float
    temp_alert_c: float
    rh_alert_pct: float
    hot_retention_days: int
    alert_suppression_minutes: int
    metrics_namespace: str
    log_level: str

    @classmethod
    def from_env(cls) -> Settings:
        """Build settings from the process environment.

        Returns:
            A populated :class:`Settings` instance.

        Raises:
            RuntimeError: If a required environment variable is absent, or
                if a numeric variable cannot be parsed. The error names the
                offending variable so a cold-start failure is diagnosable
                from a single log line.
        """

        def require(name: str) -> str:
            value = os.environ.get(name)
            if not value:
                raise RuntimeError(f"Missing required environment variable: {name}")
            return value

        def require_float(name: str) -> float:
            raw = require(name)
            try:
                return float(raw)
            except ValueError as exc:
                raise RuntimeError(
                    f"Environment variable {name} must be a number, got {raw!r}"
                ) from exc

        def require_int(name: str) -> int:
            raw = require(name)
            try:
                return int(raw)
            except ValueError as exc:
                raise RuntimeError(
                    f"Environment variable {name} must be an integer, got {raw!r}"
                ) from exc

        return cls(
            environment=require("ENVIRONMENT"),
            table_name=require("TABLE_NAME"),
            bucket_name=require("BUCKET_NAME"),
            alert_topic_arn=require("ALERT_TOPIC_ARN"),
            smoke_alert_ppm=require_float("SMOKE_ALERT_PPM"),
            temp_alert_c=require_float("TEMP_ALERT_C"),
            rh_alert_pct=require_float("RH_ALERT_PCT"),
            hot_retention_days=require_int("HOT_RETENTION_DAYS"),
            alert_suppression_minutes=require_int("ALERT_SUPPRESSION_MINUTES"),
            metrics_namespace=os.environ.get("METRICS_NAMESPACE", "PyroSense/Ingest"),
            log_level=os.environ.get("LOG_LEVEL", "INFO"),
        )
