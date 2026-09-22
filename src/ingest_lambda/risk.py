"""Fire-risk classification of validated telemetry.

The risk decision lives in the cloud, never on the sensor (ADR-0005 of
the simulator; ADR-0002 here): devices report raw measurements and this
module turns them into a risk level. Pure functions, no I/O — trivially
unit-testable and reusable if the rules ever move to a different engine.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from contract import TelemetryRecord


class RiskLevel(Enum):
    """Fire-risk classification of a single message.

    Members are compared by identity/equality, not by order; there is no
    ``<``/``>`` relation between levels. If severity comparison is ever
    needed, promote this to an ``IntEnum`` (and keep the string ``value``
    for serialisation).
    """

    NONE = "NONE"
    ELEVATED = "ELEVATED"
    CRITICAL = "CRITICAL"


@dataclass(frozen=True)
class RiskAssessment:
    """Outcome of evaluating one telemetry record.

    Attributes:
        level: The resulting classification.
        reasons: Human-readable explanation of every rule that fired,
            included verbatim in alert notifications.
    """

    level: RiskLevel
    reasons: tuple[str, ...]


def evaluate(
    record: TelemetryRecord,
    *,
    smoke_alert_ppm: float,
    temp_alert_c: float,
    rh_alert_pct: float,
) -> RiskAssessment:
    """Classify one telemetry record.

    Rules (deliberately simple and explainable — every alert email must
    be defensible in front of an operator):

    * ``CRITICAL``: smoke at or above ``smoke_alert_ppm``. Smoke is the
      primary signal; baseline noise sits around 0.02-0.03 ppm.
    * ``ELEVATED``: hot **and** dry (temperature at or above
      ``temp_alert_c`` with humidity at or below ``rh_alert_pct``) —
      the pre-fire weather pattern of the January 2024 Bogotá events.
    * ``NONE``: everything else.

    The smoke rule is evaluated after the hot-and-dry rule and is not an
    ``elif``: both reasons accumulate, but a CRITICAL smoke reading wins
    the final level.

    Args:
        record: Validated telemetry message.
        smoke_alert_ppm: CRITICAL smoke threshold.
        temp_alert_c: ELEVATED temperature threshold.
        rh_alert_pct: ELEVATED humidity threshold.

    Returns:
        The risk assessment for this record.
    """
    reasons: list[str] = []
    level = RiskLevel.NONE

    if record.temp_c >= temp_alert_c and record.rh_pct <= rh_alert_pct:
        level = RiskLevel.ELEVATED
        reasons.append(
            f"hot-and-dry conditions: temp {record.temp_c:.1f} C >= {temp_alert_c:.1f} C "
            f"with RH {record.rh_pct:.1f}% <= {rh_alert_pct:.1f}%"
        )

    if record.smoke_ppm >= smoke_alert_ppm:
        level = RiskLevel.CRITICAL
        reasons.append(
            f"smoke concentration {record.smoke_ppm:.2f} ppm >= {smoke_alert_ppm:.2f} ppm"
        )

    return RiskAssessment(level=level, reasons=tuple(reasons))
