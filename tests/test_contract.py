"""Tests for contract.validate_payload, incl. regression for 3 review bugs."""

from __future__ import annotations

import json

import pytest

from conftest import make_payload
from contract import ContractViolationError, validate_payload


def test_valid_payload_returns_record() -> None:
    record = validate_payload(make_payload())
    assert record.device_id == "PYRO-T1-0042"
    assert record.tier == "T1"
    assert record.seq == 1337
    assert record.wind_speed_ms == 5.2


def test_non_object_rejected() -> None:
    with pytest.raises(ContractViolationError):
        validate_payload(["not", "an", "object"])


def test_unknown_field_rejected() -> None:
    with pytest.raises(ContractViolationError, match="unknown fields"):
        validate_payload(make_payload(rogue_field=1))


def test_missing_required_field_rejected() -> None:
    payload = make_payload()
    del payload["temp_c"]
    with pytest.raises(ContractViolationError, match="missing required fields"):
        validate_payload(payload)


def test_wrong_schema_version_rejected() -> None:
    with pytest.raises(ContractViolationError, match="schema_version"):
        validate_payload(make_payload(schema_version="2.0"))


@pytest.mark.parametrize("bad_id", ["PYRO-X1-0042", "PYRO-T4-0042", "pyro-t1-0042"])
def test_bad_device_id_rejected(bad_id: str) -> None:
    with pytest.raises(ContractViolationError, match="device_id"):
        validate_payload(make_payload(device_id=bad_id))


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("temp_c", -100.0),
        ("temp_c", 200.0),
        ("rh_pct", -1.0),
        ("rh_pct", 101.0),
        ("smoke_ppm", -0.1),
        ("lat", 91.0),
        ("lon", -181.0),
    ],
)
def test_out_of_range_rejected(field: str, value: float) -> None:
    with pytest.raises(ContractViolationError, match=field):
        validate_payload(make_payload(**{field: value}))


def test_bad_status_rejected() -> None:
    with pytest.raises(ContractViolationError, match="status"):
        validate_payload(make_payload(status="ON_FIRE"))


def test_naive_timestamp_rejected() -> None:
    with pytest.raises(ContractViolationError, match="timezone-aware"):
        validate_payload(make_payload(ts_device="2026-09-07T14:23:05"))


def test_nullable_wind_fields_allowed() -> None:
    record = validate_payload(make_payload(wind_speed_ms=None, wind_dir_deg=None))
    assert record.wind_speed_ms is None
    assert record.wind_dir_deg is None


def test_bool_is_not_a_number() -> None:
    # isinstance(True, int) is True in Python: a bool must not pass as a value.
    with pytest.raises(ContractViolationError, match="temp_c"):
        validate_payload(make_payload(temp_c=True))


def test_all_errors_accumulated() -> None:
    payload = make_payload(temp_c=999.0, rh_pct=999.0, status="BAD")
    with pytest.raises(ContractViolationError) as exc_info:
        validate_payload(payload)
    assert len(exc_info.value.errors) >= 3


# --- Regression: the three bugs found in senior review ---


@pytest.mark.parametrize("bad", ["NaN", "Infinity", "-Infinity"])
def test_regression_non_finite_numbers_rejected(bad: str) -> None:
    """Bug 1: NaN/Infinity slipped past range checks."""
    payload = make_payload()
    payload["temp_c"] = json.loads(bad)  # json.loads accepts these by default
    with pytest.raises(ContractViolationError, match="temp_c"):
        validate_payload(payload)


@pytest.mark.parametrize("bad", [[], {}, ["OK"]])
def test_regression_unhashable_status_is_contract_error(bad: object) -> None:
    """Bug 2: an unhashable status raised TypeError (misclassified as transient)."""
    with pytest.raises(ContractViolationError, match="status"):
        validate_payload(make_payload(status=bad))


@pytest.mark.parametrize("bad_id", ["PYRO-T1-0042\n", "PYRO-T1-0042\nrogue"])
def test_regression_trailing_newline_in_id_rejected(bad_id: str) -> None:
    """Bug 3: the `$` anchor accepted a trailing newline; fullmatch fixes it."""
    with pytest.raises(ContractViolationError, match="device_id"):
        validate_payload(make_payload(device_id=bad_id))


# --- Type-branch coverage for numeric and timestamp fields ---


def test_non_numeric_string_rejected() -> None:
    with pytest.raises(ContractViolationError, match="temp_c"):
        validate_payload(make_payload(temp_c="hot"))


def test_null_non_nullable_rejected() -> None:
    with pytest.raises(ContractViolationError, match="temp_c"):
        validate_payload(make_payload(temp_c=None))


def test_ts_device_non_string_rejected() -> None:
    with pytest.raises(ContractViolationError, match="ts_device"):
        validate_payload(make_payload(ts_device=12345))


def test_ts_device_invalid_format_rejected() -> None:
    with pytest.raises(ContractViolationError, match="ts_device"):
        validate_payload(make_payload(ts_device="not-a-timestamp"))


def test_negative_seq_rejected() -> None:
    with pytest.raises(ContractViolationError, match="seq"):
        validate_payload(make_payload(seq=-1))


def test_wind_dir_out_of_range_rejected() -> None:
    with pytest.raises(ContractViolationError, match="wind_dir_deg"):
        validate_payload(make_payload(wind_dir_deg=400.0))
