"""Structured JSON logging for the ingest Lambda.

Every log line is a single JSON document — timestamp, level, logger,
message and a whitelist of context fields such as ``device_id`` and
``seq`` — so CloudWatch Logs Insights can query the fields directly
instead of parsing prose::

    fields @timestamp, device_id, seq, reasons
    | filter level = "WARNING"
    | stats count(*) by device_id

The JSON is produced in-process on purpose. Switching the Lambda runtime
to its own JSON log format would also wrap the raw EMF documents that
:mod:`metrics` prints on **stdout**, silently breaking CloudWatch metric
extraction. Logs go to **stderr**, metrics stay on stdout: two channels,
no collisions.

Standard library only, like the rest of the function: the deployment zip
ships no third-party packages.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime
from typing import Any

#: Record attributes copied into the JSON document when present. A closed
#: set, mirroring the contract's ``ALLOWED_KEYS``: nothing reaches
#: CloudWatch unless it is declared here, so a careless ``extra`` cannot
#: leak payload data (telemetry carries device coordinates).
CONTEXT_FIELDS = ("device_id", "seq", "message_id", "errors", "reasons")

#: Applied when the configured level name is not a known logging level.
FALLBACK_LEVEL = "INFO"


class JsonFormatter(logging.Formatter):
    """Render log records as single-line JSON documents."""

    def format(self, record: logging.LogRecord) -> str:
        """Serialize a record together with its whitelisted context fields.

        Args:
            record: The record to render, optionally carrying context
                fields passed through ``logger.*(..., extra={...})``.

        Returns:
            A single-line JSON string.
        """
        document: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        for field in CONTEXT_FIELDS:
            value = getattr(record, field, None)
            if value is not None:
                document[field] = value

        if record.exc_info:
            document["exception"] = self.formatException(record.exc_info)

        # ``default=str`` keeps an unserializable value (a Decimal read back
        # from DynamoDB, a datetime) from turning a log call into an
        # exception. Compact separators drop the cosmetic whitespace:
        # CloudWatch bills by ingested volume and renders the JSON
        # structurally anyway.
        return json.dumps(document, default=str, separators=(",", ":"))


def configure(level: str) -> None:
    """Route the root logger through the JSON formatter.

    Safe to call repeatedly. The Lambda runtime installs its own handler
    on the root logger at bootstrap, so this reformats what is already
    attached rather than stacking a second handler, which would duplicate
    every line. Outside Lambda — tests, local runs — there is no handler
    yet and one is attached, bound explicitly to stderr.

    An unrecognized level name degrades to ``INFO`` instead of raising: a
    typo in an observability setting must never stop fire detection.
    ``lambda_log_level`` should also be constrained at ``terraform plan``
    time so the typo never reaches the runtime in the first place.

    Args:
        level: Logging level name (``DEBUG``, ``INFO``, ``WARNING``...).
    """
    root = logging.getLogger()
    if not root.handlers:
        # Explicitly stderr: stdout belongs to the EMF metric documents.
        root.addHandler(logging.StreamHandler(sys.stderr))

    formatter = JsonFormatter()
    for handler in root.handlers:
        handler.setFormatter(formatter)

    resolved = logging.getLevelNamesMapping().get(level.upper())
    if resolved is None:
        root.setLevel(FALLBACK_LEVEL)
        root.warning("Unknown log level %r, falling back to %s", level, FALLBACK_LEVEL)
    else:
        root.setLevel(resolved)
