"""Custom metrics via CloudWatch Embedded Metric Format (EMF).

EMF turns a structured log line into CloudWatch metrics asynchronously:
no ``PutMetricData`` calls, no extra IAM permissions, no latency added to
the hot path. The ingest Lambda emits one EMF line per invocation with
the batch outcome counters.
"""

from __future__ import annotations

import json
import time


def emit_counts(namespace: str, environment: str, counts: dict[str, int]) -> None:
    """Emit counters as one EMF log line on stdout.

    Args:
        namespace: CloudWatch metrics namespace (e.g. ``PyroSense/Ingest``).
        environment: Value of the ``Environment`` dimension.
        counts: Metric name -> count. Zero values are included on
            purpose so dashboards show a continuous zero line instead
            of gaps.
    """
    # An EMF directive with an empty Metrics array is rejected by
    # CloudWatch; emit nothing rather than a malformed document.
    if not counts:
        return
    document = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": namespace,
                    "Dimensions": [["Environment"]],
                    "Metrics": [{"Name": name, "Unit": "Count"} for name in counts],
                }
            ],
        },
        "Environment": environment,
        **counts,
    }
    print(json.dumps(document))
