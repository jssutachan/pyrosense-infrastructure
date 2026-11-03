#!/usr/bin/env python3
"""Policy gate between a Terraform plan and `terraform apply` (ADR-0025).

The deploy workflow plans twice: once before the approval (so the reviewer
sees what will happen) and once after it (with the apply role). This script
reads the JSON of a saved plan (`terraform show -json tfplan`) and:

1. Fingerprints the plan: a SHA-256 over every managed resource address and
   its actions, never over values. The second plan must have the same
   fingerprint as the first, so what is applied is what was approved.
2. Enforces what each operation may do:
     apply    create, update, no-op. A delete, including the delete half of a
              replace, is refused, except the replacement of a resource that a
              failed earlier apply left tainted (the only way to recover).
     destroy  delete, no-op. Nothing may be created or changed.
   An action this script does not know is refused: fail closed.
   In apply, a resource that is in the state but that the refresh could no
   longer find (resource_drift: delete) and that the plan would create again
   is refused too: either someone deleted it outside Terraform, or the
   planning role is missing a read permission. Either way a person decides,
   not the pipeline. A tainted replacement is allowed but always reported.
3. For `drift`, lists the addresses of a refresh-only plan's resource_drift.

Prints key=value lines on stdout (for $GITHUB_OUTPUT) and diagnostics on
stderr. It prints resource addresses and actions only: plan values hold
email addresses and ARNs, and the workflow log is public.

Exit status: 0 allowed, 1 refused or mismatched, 2 unreadable input.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

KNOWN_ACTIONS = frozenset({"no-op", "create", "update", "delete"})
ALLOWED = {
    "apply": frozenset({"no-op", "create", "update"}),
    "destroy": frozenset({"no-op", "delete"}),
}
TAINTED = "replace_because_tainted"


@dataclass(frozen=True)
class Change:
    """One managed resource of the plan: its address, actions and reason."""

    address: str
    actions: tuple[str, ...]
    reason: str | None


def load(path: Path) -> dict[str, Any]:
    """Read the JSON of a saved plan (terraform show -json)."""
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError("plan JSON is not an object")
    return data


def managed_changes(plan: dict[str, Any]) -> list[Change]:
    """Return the changes to managed resources; data sources are reads, not changes."""
    changes = []
    for entry in plan.get("resource_changes", []):
        if entry.get("mode") != "managed":
            continue
        changes.append(
            Change(
                address=str(entry["address"]),
                actions=tuple(str(a) for a in entry["change"]["actions"]),
                reason=entry.get("action_reason"),
            )
        )
    return sorted(changes, key=lambda c: c.address)


def fingerprint(changes: Sequence[Change]) -> str:
    """Return a SHA-256 over every address and its actions, never over values."""
    canonical = json.dumps([[c.address, list(c.actions)] for c in changes], separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def has_changes(changes: Sequence[Change]) -> bool:
    """Return True when any managed resource would change."""
    return any(c.actions != ("no-op",) for c in changes)


def lost_addresses(plan: dict[str, Any]) -> frozenset[str]:
    """Return managed resources in the state that the refresh no longer found."""
    return frozenset(
        str(entry["address"])
        for entry in plan.get("resource_drift", [])
        if entry.get("mode", "managed") == "managed"
        and tuple(entry["change"]["actions"]) == ("delete",)
    )


def violations(
    operation: str, changes: Sequence[Change], lost: frozenset[str] = frozenset()
) -> list[str]:
    """List the changes the operation is not allowed to make, by address."""
    allowed = ALLOWED[operation]
    found = []
    for change in changes:
        unknown = set(change.actions) - KNOWN_ACTIONS
        if unknown:
            found.append(f"{change.address}: unknown action {sorted(unknown)}")
            continue
        if operation == "apply" and change.address in lost and "create" in change.actions:
            found.append(
                f"{change.address}: in the state but no longer readable, planned as create "
                "(deleted outside Terraform, or a read permission is missing)"
            )
            continue
        refused = set(change.actions) - allowed
        if not refused:
            continue
        if operation == "apply" and refused == {"delete"} and change.reason == TAINTED:
            continue
        found.append(f"{change.address}: {'/'.join(change.actions)} is not allowed in {operation}")
    return found


def drift_addresses(plan: dict[str, Any]) -> list[str]:
    """Return the addresses of a refresh-only plan's resource_drift."""
    return sorted(str(entry["address"]) for entry in plan.get("resource_drift", []))


def main(argv: Sequence[str] | None = None) -> int:
    """Run the gate and return the exit status (0 allowed, 1 refused, 2 unreadable)."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--operation", required=True, choices=["apply", "destroy", "drift"])
    parser.add_argument("--expect", help="fingerprint the plan must match")
    parser.add_argument("plan_json", type=Path)
    args = parser.parse_args(argv)

    try:
        plan = load(args.plan_json)
        if args.operation == "drift":
            drifted = drift_addresses(plan)
            for address in drifted:
                print(f"drift: {address}", file=sys.stderr)
            print(f"drifted={len(drifted)}")
            return 0
        changes = managed_changes(plan)
        lost = lost_addresses(plan)
    except (OSError, ValueError, KeyError, TypeError) as err:
        print(
            f"::error::plan_guard: cannot read the plan ({type(err).__name__})",
            file=sys.stderr,
        )
        return 2

    digest = fingerprint(changes)
    print(f"fingerprint={digest}")
    print(f"changes={'true' if has_changes(changes) else 'false'}")

    status = 0
    for change in changes:
        if change.reason == TAINTED:
            print(f"::warning::plan_guard: {change.address}: replaced (tainted)", file=sys.stderr)
    for problem in violations(args.operation, changes, lost):
        print(f"::error::plan_guard: {problem}", file=sys.stderr)
        status = 1
    if args.expect is not None and args.expect != digest:
        print(
            "::error::plan_guard: this plan differs from the one shown before the approval. "
            "Something changed in between; nothing was applied. Dispatch again.",
            file=sys.stderr,
        )
        status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
