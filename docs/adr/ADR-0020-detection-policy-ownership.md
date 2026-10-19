# ADR-0020: Detection policy — ownership and provisional values

- **Status:** Proposed
- **Date:** 2026-10-06
- **Scope:** root `main.tf` (detection locals), `modules/ingest` (validation only)
- **Decision owner:** domain stakeholder (fire agency, e.g. Bomberos Bogotá or IDIGER) — **not assigned**. Engineering owns the mechanism and its guardrails, not the values.
- **Related:** ADR-0002, ADR-0005, ADR-0015, ADR-0019

## Context

The ingest Lambda classifies each reading (`risk.py`):

- **CRITICAL** when `smoke_ppm ≥ SMOKE_ALERT_PPM`. Only CRITICAL publishes an
  alert (`handler.py:117`).
- **ELEVATED** when `temp_c ≥ TEMP_ALERT_C` **and** `rh_pct ≤ RH_ALERT_PCT`.
  In v1 this only adds a reason to the assessment; it never sends anything.
- Alerts for the same device are spaced by `ALERT_SUPPRESSION_MINUTES`
  (`alerts.py`, ADR-0005).

`risk.py` and `config.py` take these four values as required inputs with no
defaults. Before `modules/ingest`, no document, ADR or configuration in the
repository set them. The only values were test fixtures, repeated identically
in `tests/test_config.py:16-20`, `tests/test_handler.py:30-34` and
`tests/test_error_paths.py:54-58`. The system had a detection policy, but an
implicit one, owned by nobody.

These thresholds decide when a fire alert reaches a responder. That is a
domain decision, like a fraud-score threshold set by a risk team rather than
by the engineers who run the payment platform. The engineering decision is
how the policy is represented, validated and changed.

## Decision

1. **Separate policy from mechanism.** The four values live in one place, the
   root `locals` of `main.tf`, next to the other design constants. They are not
   module defaults, environment variables typed by hand, or tfvars: they are
   identical in demo and prod (ADR-0002), and they must be readable as policy.
   `modules/ingest` receives them as required inputs and validates them; it
   never chooses them.

2. **Provisional values, pending sign-off by the domain owner:**

   | Setting | Value | Effect |
   |---|---|---|
   | `SMOKE_ALERT_PPM` | 5.0 | CRITICAL → alert |
   | `TEMP_ALERT_C` | 30.0 | ELEVATED (with humidity) → reason only |
   | `RH_ALERT_PCT` | 25.0 | ELEVATED (with temperature) → reason only |
   | `ALERT_SUPPRESSION_MINUTES` | 30 | at most two alert emails per device per hour |

   They are the placeholder values exercised by the whole test suite since the
   ingest core was written. Adopting them makes the existing implicit policy
   explicit; it does not claim they are correct for a real fire.

3. **Guardrails, enforced at plan time** (`modules/ingest/variables.tf`):
   smoke `> 0`; temperature and humidity inside the contract-v1 ranges of the
   readings they are compared with (outside them a rule can never fire, which
   disables it with no error); suppression an integer in 1–1440 because the
   alert slot's TTL is one day (debt #15).

## Rationale

- **Ownership is the real decision.** An engineer choosing fire thresholds and
  presenting them as correct would be overstepping; leaving them implicit in
  tests is worse, because nobody would ever review them. Naming an owner, even
  an unassigned one, turns the values into an open question with a clear
  addressee.
- **The placeholders are coherent with the simulated data** [inferred from the
  simulator's project log, not field data]: the highest smoke reading of the
  simulator's 24-hour baseline was 0.063 ppm and the January 2024 replay peaked
  around 45 ppm, so 5.0 ppm separates both by about an order of magnitude on
  each side. This shows the placeholder does not break the demo; it says
  nothing about real smoke sensors.
- **ELEVATED may never fire in the simulated terrain.** The terrain sits at
  2,600–3,200 m. Whether any simulated reading ever reaches ≥ 30 °C with
  ≤ 25 % humidity is **not verified**. Because ELEVATED sends nothing in v1, a
  dead rule costs nothing today, but it would silently matter the day ELEVATED
  starts alerting. Recorded here as an open question for the domain owner.
- **Validation instead of trust.** `config.py` on `develop` parses but does not
  range-check (debts #15, #23, #24). A threshold of 0 ppm would make every
  reading CRITICAL (an alert storm); a temperature threshold above 80 °C would
  silently disable the rule. Both fail at `plan`, before any deployment.
- **v1.0 is non-life-safety** (ADR-0015). Provisional thresholds are acceptable
  only under that scope.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Keep the values only in the tests | The policy stays implicit and unreviewed; no plan can run without values |
| Module defaults in `modules/ingest` | Hides fire-detection policy inside infrastructure code |
| Root variables in tfvars | They are not a demo/prod delta; tfvars would claim they differ when they do not (ADR-0002) |
| Pick "better" values from external references | `smoke_ppm` in the simulator is synthetic: citing a real detector standard would be a false calibration |
| Record it as a decision inside ADR-0019 | Different owner, different lifecycle, different revisit triggers from the infrastructure decisions there |

## Consequences

- The ingest cycle can run with an explicit, documented policy.
- Any portfolio or interview presentation states these values as placeholders
  awaiting domain sign-off, never as tuned thresholds.
- Changing a value is a one-line change in `main.tf` plus an update to this
  ADR, reviewed like any other decision; the plan shows it as an in-place
  change of the function's environment.
- The test fixtures and the deployed policy are now two copies of the same
  numbers. If one changes, the other does not follow. Accepted for v1; see
  triggers.

## Revisit triggers

- A domain owner is named → they review the four values; this ADR is
  superseded by one carrying their decision.
- Field data from real sensors, or any sensor model with a documented smoke
  response → recalibrate `SMOKE_ALERT_PPM`.
- ELEVATED starts publishing alerts or feeding a decision → first answer the
  open question above (does it ever fire in the terrain?).
- A simulator replay where the first CRITICAL arrives later than an operator
  would accept → revisit `SMOKE_ALERT_PPM` against detection latency.
- `fix/config-validation` merges → re-check the 1440-minute upper bound.
- The test fixtures and the deployed values diverge → decide which one moves,
  or derive the fixtures from a single source.

## References

- `src/ingest_lambda/risk.py:45-93`; `handler.py:117-138`; `alerts.py:63-80`
- `tests/test_config.py:16-20`; `tests/test_handler.py:30-34`;
  `tests/test_error_paths.py:54-58`
- PyroSense-Simulator project log (`WINRY-BITACORA-SIMULATOR.md`), sessions
  2026-07-07 (7) and (11): baseline and January 2024 replay readings
- ADR-0015 (v1.0 alerting scoped as non-life-safety)
