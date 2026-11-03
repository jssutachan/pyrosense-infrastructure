"""Tests for scripts/ci/plan_guard.py, the gate between an approved plan and apply."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "ci" / "plan_guard.py"


def _load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("plan_guard", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["plan_guard"] = module
    spec.loader.exec_module(module)
    return module


pg = _load()


def _rc(
    address: str, *actions: str, reason: str | None = None, mode: str = "managed"
) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "address": address,
        "mode": mode,
        "change": {"actions": list(actions)},
    }
    if reason is not None:
        entry["action_reason"] = reason
    return entry


def _write(tmp_path: Path, plan: dict[str, Any]) -> Path:
    path = tmp_path / "plan.json"
    path.write_text(json.dumps(plan), encoding="utf-8")
    return path


def _run(tmp_path: Path, plan: dict[str, Any], *args: str) -> int:
    result: int = pg.main([*args, str(_write(tmp_path, plan))])
    return result


CREATE_PLAN = {
    "resource_changes": [
        _rc("module.security.aws_kms_key.pipeline", "create"),
        _rc("module.messaging.aws_sqs_queue.ingest", "create"),
        _rc("data.aws_iam_policy.workload_boundary", "read", mode="data"),
    ]
}


def test_fingerprint_ignores_order_and_data_sources() -> None:
    reordered = {"resource_changes": list(reversed(CREATE_PLAN["resource_changes"]))}
    no_data = {"resource_changes": CREATE_PLAN["resource_changes"][:2]}
    digests = {pg.fingerprint(pg.managed_changes(p)) for p in (CREATE_PLAN, reordered, no_data)}
    assert len(digests) == 1


def test_fingerprint_changes_when_an_action_changes() -> None:
    other = {"resource_changes": [_rc("module.security.aws_kms_key.pipeline", "update")]}
    first = pg.fingerprint(pg.managed_changes(CREATE_PLAN))
    assert first != pg.fingerprint(pg.managed_changes(other))


def test_apply_of_creates_is_allowed(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert _run(tmp_path, CREATE_PLAN, "--operation", "apply") == 0
    out = capsys.readouterr().out
    assert "changes=true" in out
    assert "fingerprint=" in out


@pytest.mark.parametrize("actions", [("delete",), ("delete", "create"), ("create", "delete")])
def test_apply_refuses_deletes_and_replaces(tmp_path: Path, actions: tuple[str, ...]) -> None:
    plan = {"resource_changes": [_rc("module.storage.aws_s3_bucket.cold", *actions)]}
    assert _run(tmp_path, plan, "--operation", "apply") == 1


def test_apply_allows_replacing_a_tainted_resource(tmp_path: Path) -> None:
    plan = {
        "resource_changes": [
            _rc(
                "module.ingest.aws_lambda_function.this",
                "delete",
                "create",
                reason=pg.TAINTED,
            )
        ]
    }
    assert _run(tmp_path, plan, "--operation", "apply") == 0


def test_tainted_reason_does_not_excuse_a_plain_destroy_action(tmp_path: Path) -> None:
    plan = {
        "resource_changes": [
            _rc(
                "module.storage.aws_s3_bucket.cold",
                "delete",
                reason="delete_because_no_module",
            )
        ]
    }
    assert _run(tmp_path, plan, "--operation", "apply") == 1


def test_destroy_allows_only_deletes(tmp_path: Path) -> None:
    deletes = {"resource_changes": [_rc("module.security.aws_kms_key.pipeline", "delete")]}
    assert _run(tmp_path, deletes, "--operation", "destroy") == 0
    assert _run(tmp_path, CREATE_PLAN, "--operation", "destroy") == 1


def test_unknown_action_fails_closed(tmp_path: Path) -> None:
    plan = {"resource_changes": [_rc("module.budgets.aws_budgets_budget.monthly_cost", "forget")]}
    assert _run(tmp_path, plan, "--operation", "apply") == 1
    assert _run(tmp_path, plan, "--operation", "destroy") == 1


def test_empty_plan_reports_no_changes(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    plan = {"resource_changes": [_rc("module.security.aws_kms_key.pipeline", "no-op")]}
    assert _run(tmp_path, plan, "--operation", "apply") == 0
    assert "changes=false" in capsys.readouterr().out


def test_expect_matching_fingerprint(tmp_path: Path) -> None:
    digest = pg.fingerprint(pg.managed_changes(CREATE_PLAN))
    assert _run(tmp_path, CREATE_PLAN, "--operation", "apply", "--expect", digest) == 0


def test_expect_mismatch_refuses(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert _run(tmp_path, CREATE_PLAN, "--operation", "apply", "--expect", "0" * 64) == 1
    assert "differs from the one shown before the approval" in capsys.readouterr().err


def test_drift_lists_addresses_only(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    plan = {
        "resource_drift": [
            {"address": "module.alerting.aws_sns_topic_subscription.ops", "change": {}}
        ]
    }
    assert _run(tmp_path, plan, "--operation", "drift") == 0
    captured = capsys.readouterr()
    assert "drifted=1" in captured.out
    assert "module.alerting.aws_sns_topic_subscription.ops" in captured.err


def test_unreadable_plan_exits_2(tmp_path: Path) -> None:
    path = tmp_path / "plan.json"
    path.write_text("[1, 2]", encoding="utf-8")
    assert pg.main(["--operation", "apply", str(path)]) == 2
    assert pg.main(["--operation", "apply", str(tmp_path / "missing.json")]) == 2


def test_errors_never_print_values(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    entry = _rc("module.alerting.aws_sns_topic_subscription.ops", "delete")
    entry["change"]["before"] = {"endpoint": "someone@example.org"}
    assert _run(tmp_path, {"resource_changes": [entry]}, "--operation", "apply") == 1
    captured = capsys.readouterr()
    assert "someone@example.org" not in captured.out + captured.err


def test_apply_refuses_recreating_a_resource_the_refresh_lost(tmp_path: Path) -> None:
    plan = {
        "resource_drift": [
            {
                "address": "module.storage.aws_s3_bucket.cold",
                "mode": "managed",
                "change": {"actions": ["delete"]},
            }
        ],
        "resource_changes": [
            _rc("module.storage.aws_s3_bucket.cold", "create"),
            _rc("module.storage.aws_s3_bucket_versioning.cold", "delete", "create"),
        ],
    }
    assert _run(tmp_path, plan, "--operation", "apply") == 1
    assert pg.violations("apply", pg.managed_changes(plan), pg.lost_addresses(plan))[0].startswith(
        "module.storage.aws_s3_bucket.cold: in the state but no longer readable"
    )


def test_drift_other_than_delete_is_not_lost() -> None:
    plan = {
        "resource_drift": [
            {"address": "module.alerting.aws_sns_topic.ops", "change": {"actions": ["update"]}}
        ]
    }
    assert pg.lost_addresses(plan) == frozenset()


def test_tainted_replacement_is_reported(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    plan = {
        "resource_changes": [
            _rc(
                "module.ingest.aws_lambda_function.this",
                "delete",
                "create",
                reason=pg.TAINTED,
            )
        ]
    }
    assert _run(tmp_path, plan, "--operation", "apply") == 0
    assert (
        "::warning::plan_guard: module.ingest.aws_lambda_function.this" in capsys.readouterr().err
    )
