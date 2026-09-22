"""Tests for metrics.emit_counts: valid EMF on stdout, empty-guard."""

from __future__ import annotations

import json

import pytest

import metrics


def test_emits_valid_emf(capsys: pytest.CaptureFixture[str]) -> None:
    metrics.emit_counts("PyroSense/Ingest", "demo", {"MessagesStored": 3, "Errors": 0})
    out = capsys.readouterr().out.strip()
    doc = json.loads(out)
    assert doc["_aws"]["CloudWatchMetrics"][0]["Namespace"] == "PyroSense/Ingest"
    assert doc["Environment"] == "demo"
    assert doc["MessagesStored"] == 3
    # Zero values are kept on purpose (continuous zero line, not a gap).
    assert doc["Errors"] == 0


def test_metric_names_declared(capsys: pytest.CaptureFixture[str]) -> None:
    metrics.emit_counts("NS", "demo", {"A": 1, "B": 2})
    doc = json.loads(capsys.readouterr().out)
    names = {m["Name"] for m in doc["_aws"]["CloudWatchMetrics"][0]["Metrics"]}
    assert names == {"A", "B"}


def test_empty_counts_emits_nothing(capsys: pytest.CaptureFixture[str]) -> None:
    # An EMF directive with an empty Metrics array is rejected by CloudWatch.
    metrics.emit_counts("NS", "demo", {})
    assert capsys.readouterr().out == ""
