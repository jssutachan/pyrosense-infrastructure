"""Tests for structured_logging: JSON shape, whitelist, stderr, fallback.

pytest attaches its own capture handler to the root logger during each
test, which would keep ``configure`` from installing its stderr handler.
``fresh`` clears the root logger first so each test exercises the real
``configure`` path and its output reaches ``capsys``.
"""

from __future__ import annotations

import json
import logging

import pytest

import structured_logging as sl


def fresh(level: str) -> None:
    """Clear any pre-attached handlers, then run the real configure()."""
    root = logging.getLogger()
    for handler in list(root.handlers):
        root.removeHandler(handler)
    root.setLevel(logging.WARNING)
    sl.configure(level)


def test_emits_single_line_json(capsys: pytest.CaptureFixture[str]) -> None:
    fresh("INFO")
    logging.getLogger("handler").info("hello", extra={"device_id": "PYRO-T1-0042"})
    err = capsys.readouterr().err.strip()
    assert "\n" not in err
    doc = json.loads(err)
    assert doc["level"] == "INFO"
    assert doc["logger"] == "handler"
    assert doc["device_id"] == "PYRO-T1-0042"


def test_whitelist_drops_undeclared_fields(capsys: pytest.CaptureFixture[str]) -> None:
    fresh("INFO")
    logging.getLogger("x").info("hi", extra={"seq": 1, "lat": 4.65})
    doc = json.loads(capsys.readouterr().err)
    assert doc["seq"] == 1
    assert "lat" not in doc  # not in CONTEXT_FIELDS


def test_logs_go_to_stderr_not_stdout(capsys: pytest.CaptureFixture[str]) -> None:
    fresh("INFO")
    logging.getLogger("x").warning("to stderr")
    captured = capsys.readouterr()
    assert captured.out == ""  # stdout belongs to EMF metrics
    assert "to stderr" in captured.err


def test_configure_is_idempotent(capsys: pytest.CaptureFixture[str]) -> None:
    fresh("INFO")
    sl.configure("INFO")
    sl.configure("INFO")
    logging.getLogger("x").warning("once")
    assert len(logging.getLogger().handlers) == 1
    assert capsys.readouterr().err.count("once") == 1


def test_unknown_level_falls_back_to_info(capsys: pytest.CaptureFixture[str]) -> None:
    fresh("NONSENSE")
    assert logging.getLogger().level == logging.INFO
    assert "Unknown log level" in capsys.readouterr().err


def test_exception_info_is_serialized(capsys: pytest.CaptureFixture[str]) -> None:
    fresh("DEBUG")
    try:
        raise ValueError("boom")
    except ValueError:
        logging.getLogger("x").error("failed", exc_info=True)
    doc = json.loads(capsys.readouterr().err)
    assert "exception" in doc
    assert "ValueError" in doc["exception"]


def test_compact_separators(capsys: pytest.CaptureFixture[str]) -> None:
    fresh("INFO")
    logging.getLogger("x").info("compact")
    line = capsys.readouterr().err.strip()
    assert ", " not in line
    assert '": ' not in line
