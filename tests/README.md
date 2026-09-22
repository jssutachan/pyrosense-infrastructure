# Tests — PyroSense ingest Lambda

Pytest suite for the ingest core (`src/ingest_lambda/`). **91 tests, ~99%
branch coverage.** Everything runs against an **in-memory AWS** (moto): no
account, no credentials, no cost.

---

## Running

From the **repository root** (not from `tests/`):

```bash
python3.12 -m venv .venv && source .venv/bin/activate   # first time only
pip install -r requirements-dev.txt                     # first time only
pytest                                                   # run the suite
```

> **Python 3.12+ required.** The code uses `datetime.UTC` (added in 3.11) and
> targets the 3.12 Lambda runtime. Running on 3.10 fails at import with
> `cannot import name 'UTC' from 'datetime'` — create the venv with
> `python3.12`, not the system `python3`.

Useful variations:

| Command | What it does |
| ------- | ------------ |
| `pytest -v` | List each test by name with PASSED/FAILED |
| `pytest --cov` | Add the coverage report (gate: 90%) |
| `pytest --cov --cov-report=html` | Browsable line-by-line coverage in `htmlcov/` |
| `pytest -x` | Stop at the first failure |
| `pytest --lf` | Re-run only last-failed tests |
| `pytest tests/test_contract.py` | One file |
| `pytest -k "duplicate"` | Only tests whose name matches |

---

## Layout

| File | Covers | Notes |
| ---- | ------ | ----- |
| `conftest.py` | — | Shared fixtures: the moto AWS stack + helpers |
| `test_config.py` | `config.py` | Presence/type validation, fail-fast |
| `test_contract.py` | `contract.py` | Contract v1 + regression for 3 review bugs |
| `test_risk.py` | `risk.py` | The four risk quadrants, reason accumulation |
| `test_metrics.py` | `metrics.py` | Valid EMF, empty-guard |
| `test_structured_logging.py` | `structured_logging.py` | JSON shape, whitelist, stderr, fallback |
| `test_cold_store.py` | `cold_store.py` | Hive key, raw bytes, idempotent put |
| `test_persistence.py` | `persistence.py` | Dedup, `Decimal`, TTL, null fields |
| `test_alerts.py` | `alerts.py` | Suppression slot, self-contained SNS body |
| `test_handler.py` | `handler.py` | End-to-end pipeline, partial batch responses |
| `test_error_paths.py` | cross-cutting | Transient-vs-permanent error classification |

---

## How the fixtures work (`conftest.py`)

Effectful tests receive AWS resources as **function parameters** — pytest
*fixtures* — built fresh per test so cases never leak into each other:

| Fixture | Provides |
| ------- | -------- |
| `aws` | Activates moto + safe fake credentials for the test process |
| `dynamodb_table` | A ready single-table-design DynamoDB table |
| `s3_client` | The cold-storage bucket + S3 client |
| `sns_client` | An SNS client |
| `alert_sink` | An SNS topic **with an SQS queue subscribed**, plus `received()` — so a test can read back exactly what was published and assert on it |

Non-fixture helpers are imported directly: `make_payload(**overrides)` builds a
valid contract-v1 payload, `sqs_event(*bodies)` wraps bodies as an SQS event.

---

## Conventions

- **AAA**: each test *Arranges* data, *Acts* on one function, *Asserts* the result.
- **Deterministic time**: a fixed `NOW` constant, never the wall clock, so
  time-based assertions (TTL, suppression windows) are reproducible.
- **The name is the spec**: `test_duplicate_returns_false` tells you what broke
  without reading the body.
- **Forced failures**: `test_error_paths.py` uses a fake `_RaisingTable` and
  `monkeypatch` to trigger AWS errors moto won't raise on its own — proving the
  transient-vs-permanent classification that drives retries.

---

## Relationship to CI

The GitHub Actions pipeline runs exactly these commands (`ruff`, `mypy`,
`pytest --cov`) on every push and pull request. **If `pytest` is green locally,
CI is green** — local is the rehearsal, CI is the gate.
