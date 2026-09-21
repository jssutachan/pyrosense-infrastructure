"""Tests for config.Settings: presence and type validation, fail-fast."""

from __future__ import annotations

from dataclasses import FrozenInstanceError

import pytest

from config import Settings

REQUIRED_ENV = {
    "ENVIRONMENT": "demo",
    "TABLE_NAME": "t",
    "BUCKET_NAME": "b",
    "ALERT_TOPIC_ARN": "arn:aws:sns:us-east-1:000000000000:alerts",
    "SMOKE_ALERT_PPM": "5.0",
    "TEMP_ALERT_C": "30.0",
    "RH_ALERT_PCT": "25.0",
    "HOT_RETENTION_DAYS": "7",
    "ALERT_SUPPRESSION_MINUTES": "30",
}


def _set_env(monkeypatch: pytest.MonkeyPatch, **overrides: str) -> None:
    for key in [*REQUIRED_ENV, "METRICS_NAMESPACE", "LOG_LEVEL"]:
        monkeypatch.delenv(key, raising=False)
    for key, value in {**REQUIRED_ENV, **overrides}.items():
        monkeypatch.setenv(key, value)


def test_from_env_builds_settings(monkeypatch: pytest.MonkeyPatch) -> None:
    _set_env(monkeypatch)
    settings = Settings.from_env()
    assert settings.table_name == "t"
    assert settings.smoke_alert_ppm == 5.0
    assert settings.hot_retention_days == 7
    # Optional vars fall back to their defaults.
    assert settings.metrics_namespace == "PyroSense/Ingest"
    assert settings.log_level == "INFO"


def test_settings_is_frozen(monkeypatch: pytest.MonkeyPatch) -> None:
    _set_env(monkeypatch)
    settings = Settings.from_env()
    with pytest.raises(FrozenInstanceError):
        settings.table_name = "other"  # type: ignore[misc]


@pytest.mark.parametrize("missing", list(REQUIRED_ENV))
def test_missing_required_var_fails_fast(monkeypatch: pytest.MonkeyPatch, missing: str) -> None:
    _set_env(monkeypatch)
    monkeypatch.delenv(missing, raising=False)
    with pytest.raises(RuntimeError, match=missing):
        Settings.from_env()


@pytest.mark.parametrize("var", ["SMOKE_ALERT_PPM", "TEMP_ALERT_C", "RH_ALERT_PCT"])
def test_non_numeric_float_names_the_variable(monkeypatch: pytest.MonkeyPatch, var: str) -> None:
    _set_env(monkeypatch, **{var: "not-a-number"})
    with pytest.raises(RuntimeError, match=var):
        Settings.from_env()


@pytest.mark.parametrize("var", ["HOT_RETENTION_DAYS", "ALERT_SUPPRESSION_MINUTES"])
def test_non_integer_names_the_variable(monkeypatch: pytest.MonkeyPatch, var: str) -> None:
    _set_env(monkeypatch, **{var: "7.5"})
    with pytest.raises(RuntimeError, match=var):
        Settings.from_env()
