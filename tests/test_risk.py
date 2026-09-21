"""Tests for risk.evaluate: the four risk quadrants and reason accumulation."""

from __future__ import annotations

from conftest import make_payload
from contract import validate_payload
from risk import RiskLevel, evaluate

THRESHOLDS = {"smoke_alert_ppm": 5.0, "temp_alert_c": 30.0, "rh_alert_pct": 25.0}


def _evaluate(**overrides: float) -> object:
    record = validate_payload(make_payload(**overrides))
    return evaluate(record, **THRESHOLDS)


def test_critical_on_smoke() -> None:
    result = _evaluate(temp_c=20.0, rh_pct=60.0, smoke_ppm=47.3)
    assert result.level is RiskLevel.CRITICAL
    assert len(result.reasons) == 1


def test_elevated_on_hot_and_dry() -> None:
    result = _evaluate(temp_c=31.4, rh_pct=18.0, smoke_ppm=0.02)
    assert result.level is RiskLevel.ELEVATED
    assert len(result.reasons) == 1


def test_normal_when_nothing_fires() -> None:
    result = _evaluate(temp_c=15.0, rh_pct=60.0, smoke_ppm=0.02)
    assert result.level is RiskLevel.NONE
    assert result.reasons == ()


def test_reasons_accumulate_but_critical_wins() -> None:
    # Hot-and-dry AND smoke: level is CRITICAL, but both reasons are kept.
    result = _evaluate(temp_c=31.4, rh_pct=18.0, smoke_ppm=47.3)
    assert result.level is RiskLevel.CRITICAL
    assert len(result.reasons) == 2


def test_boundary_is_inclusive() -> None:
    # smoke exactly at threshold triggers CRITICAL (>=).
    result = _evaluate(temp_c=20.0, rh_pct=60.0, smoke_ppm=5.0)
    assert result.level is RiskLevel.CRITICAL


def test_reasons_are_immutable_tuple() -> None:
    result = _evaluate(smoke_ppm=47.3)
    assert isinstance(result.reasons, tuple)
