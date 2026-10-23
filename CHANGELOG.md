# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository scaffolding: directory structure, editor configuration and license.
- Terraform version contract pinning Terraform >= 1.11 and the AWS provider 6.x.
- Quality gate: TFLint with the AWS and Terraform rulesets, Trivy for
  misconfiguration scanning, Gitleaks for secret detection, and Ruff, mypy and
  pytest for Python.
- `pre-commit` configuration running the gate locally before every commit.
- `Makefile` as the single entry point for the gate and Terraform operations.
- Architecture Decision Record framework under `docs/adr/`.
- `config/backend.hcl.example` documenting the partial backend configuration.
- Remote state backend (`bootstrap/state-backend`): a versioned, SSE-S3
  encrypted, TLS-only S3 bucket with native lockfile locking and 90-day
  noncurrent-version expiry. (ADR-0001)
- Root module composition: the `budgets` and `security` module wiring, root
  inputs (`resource_prefix`, `budget_limit_usd`, `ops_emails`,
  `kms_deletion_window_days`), a `name_prefix` local, and re-exported
  `budget_arn`, `budget_name`, `kms_key_arn` and `kms_alias_name` outputs.
- `modules/budgets`: account-wide monthly cost budget (FinOps guardrail).
  ACTUAL and FORECASTED email alerts; measures gross consumption
  (`include_credit = false`) so free-tier credits do not mask spend.
  Monitoring-only, `$0` cost. (ADR-0003)
- `modules/security`: the single customer-managed KMS key encrypting every
  component that stores data at rest (SQS + DLQ, DynamoDB, S3, SNS, CloudWatch
  Logs), plus its alias. Symmetric, single-region, annual rotation. The key
  policy carries four statements: IAM delegation for services calling KMS with
  the caller's credentials, and one statement each for the CloudWatch Logs,
  CloudWatch Alarms and SNS service principals, which have no IAM identity and
  can only be authorized in the key policy. The Logs grant is constrained by
  `ArnLike` on the log-group encryption context. (ADR-0010)
- `modules/messaging`: standard SQS ingest queue and dead-letter queue, the
  buffer between IoT Core and the ingest Lambda. Both queues use SSE-KMS with
  the pipeline key, relying on the existing IAM delegation statement (no key
  policy change). The visibility timeout is derived from the consumer's
  settings (6 × function timeout + batching window) rather than configured.
  Retention is 4 days on the source and 14 days on the DLQ, guarded by a
  `precondition` because standard queues keep the original enqueue timestamp.
  `maxReceiveCount = 5`. The redrive contract is enforced on both sides
  (`aws_sqs_queue_redrive_policy` plus a `byQueue` redrive allow policy).
  (ADR-0008, ADR-0010)
- Root module: `messaging` wiring; `ingest_lambda_timeout_seconds` and
  `ingest_batching_window_seconds` locals as the single source of the consumer
  settings shared by `messaging` and the future `ingest` module; re-exported
  `ingest_queue_url`, `ingest_queue_arn`, `ingest_dlq_url` and
  `ingest_dlq_arn` outputs. No new root inputs.
- `modules/storage`: the hot/cold persistence split. A DynamoDB table
  (`<prefix>-hot`) with generic `pk`/`sk` string keys shared by two item
  families — telemetry (`DEV#<device_id>` / `SEQ#<seq>`) and the
  alert-suppression slot (`ALERT#<device_id>` / `STATE`) — mirroring the
  approved Python exactly; on-demand, TTL on `expires_at`, point-in-time
  recovery always on (35 days), SSE with the pipeline key. An S3 bucket
  (`<prefix>-cold-<account_id>`) archiving every raw message: SSE-KMS with an
  S3 Bucket Key, SSE-C blocked, versioning, all public access blocked, and a
  single hygiene lifecycle rule (noncurrent versions after 30 days, orphan
  delete markers, incomplete multipart uploads after 7 days). No storage-class
  transitions: per-message objects are under the 128 KB lifecycle floor and
  would cost more in IA or Glacier. Outputs include `telemetry_objects_arn` so
  the ingest role's `s3:PutObject` is scoped to `telemetry/*` without
  re-typing the prefix. (ADR-0008, ADR-0010, ADR-0013)
- Root module: `storage` wiring; `allow_data_destruction` input (default
  `false`, cross-variable validation rejecting `true` for `prod`), driving
  DynamoDB deletion protection and S3 `force_destroy` together; re-exported
  `hot_table_name`, `hot_table_arn`, `cold_bucket_id` and `cold_bucket_arn`
  outputs.
- `trivy.yaml`: committed scanner configuration excluding `.venv`, `.terraform`
  and `.git`, so local runs and CI scan the same tree.
- `demo.tfvars.example` / `prod.tfvars.example` templates for the two
  deployment scenarios. (ADR-0002)
- Ingest core Lambda (`src/ingest_lambda/`, Python 3.12): the only component
  with business logic. Nine standard-library-only modules —
  `config` (env-driven `Settings`, fail-fast), `contract` (frozen contract v1
  validation → immutable `TelemetryRecord`), `risk` (pure fire-risk
  classification with explainable reasons), `persistence` (DynamoDB hot write,
  conditional-write dedup, TTL), `cold_store` (raw S3 archive, Hive-partitioned
  deterministic key), `alerts` (SNS publish with race-free per-device
  suppression), `metrics` (CloudWatch EMF on stdout), `structured_logging`
  (JSON logs on stderr, whitelisted context fields) and `handler`
  (SQS batch orchestration with partial batch responses). No runtime
  dependencies; `boto3` is provided by the Lambda runtime.
  (ADR-0005, ADR-0006, ADR-0007, ADR-0008, ADR-0009)
- Test suite (`tests/`): 95 pytest tests (was 91), ~99% branch coverage, running against
  an in-memory AWS (moto) — no account, no credentials, no cost. `conftest.py`
  provisions a fresh DynamoDB/S3/SNS stack per test and wires an SQS queue to
  the SNS topic to assert on published alerts. Includes regression tests for the
  three correctness bugs found in review and transient-vs-permanent error-path
  coverage.
- Python tooling in `pyproject.toml`: coverage configuration with a 90% branch
  gate (`[tool.coverage.*]`), alongside the existing Ruff/mypy/pytest config.
- `requirements-dev.txt`: development-only tooling (never shipped in the Lambda
  zip), version-pinned with compatible-release specifiers.
- CI pipeline (`.github/workflows/ci.yml`, GitHub Actions): runs the Python
  quality gate (Ruff lint + format, mypy, pytest with coverage) on every push
  and pull request that touches the Lambda. Least-privilege `contents: read`,
  concurrency cancel-in-progress, path-filtered to the Python project, and
  pinned to Python 3.12 to match the runtime.
- Component documentation: `src/ingest_lambda/README.md` (modules, design
  invariants, packaging), `tests/README.md` (how to run, fixtures, conventions),
  `modules/budgets/README.md`, `modules/security/README.md`,`modules/messaging/README.md` and `modules/storage/README.md` (design decisions, IAM contract for the
  producer and consumer roles, KMS cost model, plan and runtime verification).
- ADR-0005 — Alert suppression: race-free slot, claimed before publishing.
- ADR-0006 — Contract-first re-validation at the consumer boundary.
- ADR-0007 — Dependency-free Lambda (standard library only).
- ADR-0008 — At-least-once delivery handled by idempotent conditional writes.
- ADR-0009 — Observability: JSON logs on stderr, EMF metrics on stdout.
- ADR-0010 — A single customer-managed KMS key for the whole pipeline.
- ADR-0011 — Ingest buffer retry contract: consumer-derived visibility timeout
  and a DLQ that outlives its source.
- ADR-0012 — Permanent (contract) failures stay on the SQS retry path; the DLQ
  is never redriven blindly.
- ADR-0013 — Storage: single-table key design and a flat (non-tiered) cold
  archive.
- Root `README.md`: added `modules/storage` to the repository structure,
  roadmap and ADR index; split Athena into its own roadmap row; corrected the
  status paragraph, which still described messaging as pending deployment.
- `demo.tfvars.example` / `prod.tfvars.example`: added
  `allow_data_destruction` (`true` for the demo cycle, `false` for prod).
- `modules/alerting`: the notification layer, two KMS-encrypted SNS standard
  topics with email subscriptions. The fire-risk topic is published by the
  ingest Lambda through its IAM role; the operations topic by CloudWatch Alarms
  as a service principal. They are written out as two topics rather than one
  generic module instantiated twice because that difference in publisher is the
  whole design: `aws_sns_topic_policy` replaces a topic's default policy, and a
  service principal has no IAM identity to fall back on, so the ops topic
  carries an explicit CloudWatch statement scoped to this account and to alarm
  ARNs in this region, while the fire topic carries only the TLS deny. Both
  topics are standard, not FIFO, stated explicitly because `alerts.py` sends no
  MessageGroupId and FIFO topics cannot deliver to email at all. Subscriptions
  are keyed by recipient label, never by address. (ADR-0014, ADR-0015)
- Root module: `alerting` wiring; `ops_recipients` and `fire_alert_recipients`
  inputs (sensitive maps of label to address); re-exported `alerts_topic_arn`
  and `ops_topic_arn` outputs.
- ADR-0014 — Alerting: one module with two purpose-built topics, keyed by
  recipient labels.
- ADR-0015 — Email as the only alert channel in v1.0, scoped as non-life-safety.
- Root `README.md`: added `modules/alerting` to the repository structure,
  roadmap and ADR index.
- `modules/iot`: the system boundary. One fleet-client identity — a Thing, an
  X.509 certificate issued from a CSR (the private key is generated on the
  operator's machine and never reaches Terraform or its state) and an IoT
  policy that allows `iot:Connect` only as the Thing's own name and
  `iot:Publish` only to `{base}/{env}/telemetry/PYRO-T?-????`, both
  conditioned on `iot:Connection.Thing.IsAttached`. A topic rule
  (`SELECT *`, no `WHERE`, SQL version 2016-03-23) forwards telemetry
  unchanged into the messaging queue through a role scoped to
  `sqs:SendMessage` and the pipeline key; failed deliveries go to a dedicated,
  CMK-encrypted log group (14-day retention) through a second role, so a broken
  forwarding policy cannot silence the error path. Account-level IoT logging is
  deliberately left out: the provider's delete is a no-op, which would leave
  orphaned account configuration after every demo destroy.
  (ADR-0016, ADR-0017, ADR-0018)
- Root module: `iot` wiring, with `topic_base` reusing `resource_prefix` and
  the `{env}` topic level reusing `environment`; `iot_fleet_client_csr_path`
  input (one key pair per environment, no default); re-exported `iot_*`
  outputs, including `iot_simulator_env` (the simulator's connection settings
  as one block) and the certificate PEM (sensitive).
- ADR-0016 — IoT: one fleet-client identity and one IoT policy.
- ADR-0017 — IoT: device certificate issued from a CSR inside Terraform;
  private key never in state.
- ADR-0018 — IoT: topic rule → SQS, no filtering, error action to a dedicated
  log group.
- Root `README.md`: added `modules/iot` to the repository structure, roadmap
  and ADR index; documented the CSR prerequisite in Getting started.
- `demo.tfvars.example` / `prod.tfvars.example`: added
  `iot_fleet_client_csr_path`.
- `modules/ingest`: the consumer of the pipeline. A Python 3.12 Lambda on
  arm64, zipped straight from `src/ingest_lambda` (bytecode excluded, file
  modes pinned so the hash is stable across machines), fed by an SQS event
  source with partial batch responses, a batch of 10, a 0 s window and a
  maximum concurrency of 2, without reserved concurrency. Every environment
  variable `config.py` reads is injected explicitly and checked non-empty at
  plan time; the detection thresholds and suppression window are validated
  against the contract-v1 ranges as defense in depth for `config.py`.
  `HOT_RETENTION_DAYS` is derived from messaging's retentions (19 days) so a
  redriven duplicate still finds its hot item. The log group is declared
  before the function (14-day retention, pipeline key, `Text` format so the
  EMF lines are extracted). No X-Ray. (ADR-0008, ADR-0009, ADR-0011, ADR-0019)
- `modules/messaging`: `message_retention_seconds` and
  `dlq_message_retention_seconds` outputs, consumed by `modules/ingest` to
  derive the hot-retention floor. No resource changes. (ADR-0011, ADR-0019)
- Root module: `ingest` wiring, consuming security, messaging, storage and
  alerting; the v1 fire-detection policy (smoke 5.0 ppm, 30 °C with 25 % RH,
  30-minute suppression) as root locals, as provisional placeholders
  pending domain sign-off (ADR-0020); the `archive` provider
  (`~> 2.8`) enabled; re-exported `ingest_function_name`,
  `ingest_event_source_mapping_uuid`, `ingest_log_group_name`,
  `ingest_metrics_namespace` and `ingest_role_arn` outputs. No new root inputs.
- ADR-0019 — Ingest consumer: runtime, configuration contract, concurrency and
  IAM scoping.
- ADR-0020 — Detection policy: ownership and provisional values. The fire
  thresholds are a domain decision (owner not assigned); engineering owns the
  mechanism and its plan-time guardrails.
- Root `README.md`: added `modules/ingest` to the repository structure,
  roadmap and ADR index.
- `modules/observability`: the answer to "who finds out if this fails?" for
  every boundary of the pipeline. Ten CloudWatch alarms, each owning one fault
  at the layer where it first becomes visible: fleet silence (IoT
  `TopicMatch`, missing data treated as breaching), denied MQTT publishes, IoT
  rule → SQS failures, ingest queue age above two visibility timeouts, a
  non-empty DLQ, Lambda errors and throttles, per-message dependency failures,
  lost fire alerts (`AlertPublishFailures`) and failed fire-alert deliveries.
  Every alarm notifies the KMS-encrypted ops topic on ALARM and on OK; no
  composite alarm, because actions fire on transitions and the signals do not
  overlap. Missing-data treatment is chosen per alarm; the DLQ keeps its last
  state because SQS stops emitting metrics for a dormant queue even while it
  holds messages. Two log metric filters turn existing lines into signals
  (`TransientFailures`, which Lambda `Errors` cannot see because the handler
  catches per-message exceptions, and `RuleErrorDocuments` as a cross-check),
  and one dashboard shows both sides of every boundary in data-flow order.
  No KMS input, no IAM, no log group: the alarms reach the topic as a service
  principal authorized by the key and topic policies. (ADR-0021)
- `modules/messaging`: `visibility_timeout_seconds` output, consumed by
  `modules/observability` to derive the queue-age alarm threshold. No resource
  changes. (ADR-0011, ADR-0021)
- Root module: `observability` wiring, consuming messaging, ingest, iot and
  alerting; `observability_telemetry_silence_minutes` local (10 minutes,
  provisional operations policy); re-exported `observability_alarm_names`,
  `observability_alarm_name_prefix`, `observability_dashboard_name` and
  `observability_log_metrics_namespace` outputs. No new root inputs; the
  demo/prod tfvars are unchanged. (ADR-0021)
- ADR-0021 — Observability: one fault, one page; fleet silence as a breaching
  heartbeat; no account-level IoT logging and manual replay of IoT rule errors
  in v1.0.
- Ingest Lambda: a fire alert that cannot be published after its suppression
  slot was claimed is now observable. The handler counts it in a new EMF
  counter, `AlertPublishFailures` (emitted on every invocation, zero
  included), and logs one CRITICAL line carrying `message_id`, `device_id` and
  `seq`, so an operator can notify responders by hand; the message is still
  retried for its S3 and hot-store writes. Claim-before-publish is unchanged
  (ADR-0005): releasing the slot so the retry can deliver the alert is
  deferred. (ADR-0005, ADR-0015, ADR-0021)
- Tests pinning the observability contracts of the handler: the six EMF
  counter names and their dimension, and the `Processing failed` prefix of the
  transient-failure log line, which a CloudWatch metric filter counts.
- CI runs the full static quality gate as four required checks on every pull
  request and push to `develop` and `main`: `python` (`make py-lint py-type
  py-test`), `terraform` (`make fmt-check validate lint`), `security`
  (`make sec`) and `hygiene` (`make guard ci-lint`). Every job calls the same
  `make` targets used locally, so the gate is defined once. (ADR-0022)
- `.tool-versions`: the single pin for Python, Terraform, TFLint, Trivy,
  gitleaks and actionlint, read natively by `actions/setup-python` and by
  asdf/mise locally. (ADR-0022)
- `scripts/tooling/`: `install-tool.sh` installs a pinned binary only after
  checking its SHA-256 against `checksums.txt`, committed in this repository;
  `check-tool-versions.sh` backs `make tools`; `trivy-gate.sh` is the Trivy
  gate; `guard.sh` backs `make guard`. (ADR-0022)
- `make guard` (`scripts/tooling/guard.sh`): fails if a plan, state, tfvars,
  backend configuration, CSR or key is tracked, including files added with
  `git add -f`, and if a committed `*.example` template carries an email
  address outside the reserved example domains or a 12-digit AWS account id.
  Findings report file and line only, never the value, because CI logs are
  public.
- `make ci-lint`: lints the GitHub Actions workflows with actionlint, also run
  as a pre-commit hook on workflow changes.
- `make py-fix`: fixes and formats Python in place; the pre-commit ruff hook
  calls it.
- Repository ruleset for `develop` and `main`, kept as
  `docs/github/ruleset-protected-branches.json`: the four checks required,
  pull request required, no force push, no deletion, empty bypass list.
- ADR-0022 — CI quality gate and pinned, hash-verified toolchain.

### Changed

- Re-enabled the `terraform_unused_required_providers` TFLint rule now that
  the root module declares an `aws_*` resource.
- Tag-linting strategy: replaced `aws_resource_missing_tags` with
  `aws_provider_missing_default_tags`, which validates the provider's
  `default_tags` where TFLint can read it, instead of each resource across
  the module boundary. (ADR-0004)
- Corrected the ADR references in this file: entries 0005 through 0009 were
  mapped to the wrong decisions, and the four-digit numbering now matches the
  filenames under `docs/adr/`.
- Root `README.md`: corrected the repository structure to match the actual
  layout, added the SQS buffer to the reference architecture diagram, aligned
  the ADR list and quality gate, and added a Python test quickstart (requires
  Python 3.12).
- Root `README.md`: added `modules/messaging` to the repository structure and
  roadmap, referenced ADR-0002 by number, and restated the KMS key status as
  verified in a deploy/destroy cycle with runtime use still pending.
- **Breaking (tfvars):** the root input `ops_emails` (list of addresses) is
  replaced by `ops_recipients`, a sensitive map of label to address, and joined
  by `fire_alert_recipients` in the same shape. Terraform discloses `for_each`
  keys in resource addresses, so a list of addresses would print PII in every
  plan and CI log; labels keep the addresses out of the graph and keep the keys
  stable when a recipient is added or removed. `module.budgets` now receives
  `values(var.ops_recipients)` and is otherwise untouched — one intent ("who
  operates the platform"), one input. Real `demo.tfvars` and `prod.tfvars` must
  be updated before the next plan. (ADR-0014)
- Root `README.md`: the roadmap row "IoT Core rule → SQS → Lambda" is split
  into the IoT boundary and the ingest Lambda, matching the approved topology
  (rule → SQS → Lambda); the status paragraph no longer describes alerting as
  pending deployment.
- Root `README.md`: the IoT boundary is now marked as verified in a
  deploy/destroy cycle, in both the status paragraph and the roadmap; the
  compute row of the tech stack names the architecture and the event source.
- Root `README.md`: the ingest Lambda is now marked as verified end to end in
  a deploy/destroy cycle (MQTT → IoT Core → SQS → Lambda → DynamoDB, S3 and an
  alert email); observability added to the reference architecture,
  repository structure, roadmap and ADR index; the observability row of the
  tech stack names the alarm path.
- Root `main.tf`: the ingest timeout comment records the measured Duration
  (p99 1711 ms, maximum 1715 ms over 21 invocations) and the decision to keep
  30 s, replacing "no Duration data exists yet". (ADR-0021)
- CI pipeline (`.github/workflows/ci.yml`): no longer path-filtered (a change
  confined to `scripts/` used to merge with no check), runs on
  `ubuntu-24.04` instead of `ubuntu-latest`, sets `timeout-minutes` on every
  job, and checks out with `persist-credentials: false`. (ADR-0022)
- `Makefile`: recipes run in bash with `-euo pipefail`, so a failure on the
  left side of a pipe fails the target; `make init` verifies the lock file
  (`-lockfile=readonly`) instead of rewriting it; `make lint` downloads the
  TFLint plugins first (`lint-init`); `make sec` is split into `sec-config`
  (Trivy) and `secrets` (gitleaks); `make tools` compares installed versions
  with the pins instead of only checking presence; `make check` adds `guard`
  and `ci-lint`.
- `requirements-dev.txt`: exact pins (`==`) instead of compatible-release
  specifiers, matching the environment the suite was last verified with.
  (ADR-0022)
- `.pre-commit-config.yaml`: gitleaks and ruff run as local hooks that use the
  installed binaries instead of their own pinned copies, which had drifted from
  the virtualenv and PATH (ruff 0.16.4 vs 0.16.8, gitleaks 8.30.0 vs 8.30.1);
  added an actionlint hook. (ADR-0022)
- Trivy pinned to 0.75.0 (from 0.71.2; some current checks require ≥ 0.72.0).
  `trivy.yaml` uses the checks embedded in the pinned binary
  (`rego.skip-check-update`) and scans Terraform source only
  (`misconfiguration.scanners: [terraform]`); `make sec-config` removes any
  cached checks bundle first, so local runs use the same rules as CI.
  (ADR-0022)
- `make secrets` scans the full git history (`gitleaks git`) instead of the
  files on disk (`gitleaks detect --no-git`); CI checks out full history for
  it.
- Root `README.md`: new "Continuous integration" section; status paragraph,
  tech stack, repository structure, prerequisites, roadmap and ADR index
  updated for the CI gate.
- `docs/production-readiness.md`: new "Delivery pipeline (CI/CD)" section and
  summary row.

### Fixed

- `contract` validation, from senior review of the AI-drafted ingest core:
  reject non-finite numbers (`NaN`/`Infinity` previously slipped past range
  checks); a non-hashable `status` now raises `ContractViolationError` instead
  of an unclassified `TypeError`; identifier patterns use `re.fullmatch` so a
  trailing newline can no longer pass. `config` now names the offending
  environment variable when a numeric value fails to parse.
- Trivy no longer scans `.venv`, which was being parsed as CloudFormation and
  produced 16 spurious targets per run.
- Root `README.md`: removed a stray empty code fence after the architecture
  notes, and corrected the `docs/` tree, which showed `adr/` nested inside
  `docs/adr/`.
- ADR-0006 claimed contract violations are "never retried"; they are retried
  until `maxReceiveCount` and then moved to the DLQ. Corrected to match the
  handler. ADR-0006 and ADR-0008 had unfilled template number placeholders.
- `modules/messaging/README.md`: removed a duplicated `name_prefix` row that
  contradicted the module's validation (it claimed 1-69 characters of
  `[A-Za-z0-9_-]`; the variable accepts 1-64 of `[a-z0-9-]`), updated the stale
  "not yet deployed" status, and closed the IoT + CMK open item, verified in the
  `modules/iot` runtime.
- Root `main.tf`: the header and the `module "security"` comment listed
  observability as a consumer of the KMS key ARN; it is not, since alarms are
  authorized in the key policy.
- Root `variables.tf`: the NOTE on `environment` counted four consumers and
  omitted `module.ingest`; it now lists every consumer by name.
- Root `README.md`: the status paragraph followed the opening blockquote
  without a blank line, so Markdown rendered it inside the quote.
- Root `main.tf`: the `module "ingest"` comment said "Retries belong to the
queue", wording already corrected inside the module; it now states the
  handler/queue division of labour of ADR-0011.
- `alerts.py`: SNS requires a Subject of less than 100 characters; the
  truncation limit was 100 and is now 99. Latent, since current subjects are
  about 45 characters.
- Docstrings citing the wrong ADRs: `alerts.py` now cites ADR-0005 and
  ADR-0015 instead of "the open ADR", and `persistence.py` cites ADR-0008 for
  deduplication; `structured_logging.py` no longer refers to a non-existent
  `lambda_log_level` setting.
- `make check` did not enforce the 90 % branch-coverage floor: `make py-test`
  ran pytest without `--cov`, so `fail_under` was configured but never
  applied. It now runs with coverage, locally and in CI.
- Trivy logs "Error parsing file" and still exits 0, even with
  `--exit-code 1`, so an unparsed file passed the gate unscanned.
  `scripts/tooling/trivy-gate.sh` fails the gate on any parse error. (debt #8)
- Trivy parsed saved plans (`tfplan`, `tfplan.json`) as configuration, the
  most likely cause of the parse error in the 2026-10-15 run; it now scans
  Terraform source only. (debt #8)
- A secret committed and deleted in a later commit was not detected:
  `gitleaks detect --no-git` scanned only the files on disk.
- `.pre-commit-config.yaml` stated that "the same checks run in CI"; CI ran
  only the Python half. The statement is now true.
- The CI secret scan reported only the number of leaks. `make secrets` now runs
  `scripts/tooling/gitleaks-gate.sh`, which prints rule, file, line and commit
  for each finding from a JSON report, without the secret (redacted) or the
  commit author's name and email, which `--verbose` would publish in a public
  log. (ADR-0022)

### Security

- Backend configuration is excluded from version control: the state bucket
  name carries the AWS account ID as a suffix.
- Real `*.tfvars` files are gitignored (they carry operator email
  addresses); only `*.tfvars.example` templates are committed.
- CI runs with least-privilege permissions (`contents: read` only) and never
  vendors third-party packages into the Lambda deployment artifact, keeping the
  runtime CVE surface minimal.
- Encryption at rest is centralized on one customer-managed KMS key, whose
  policy is the only surface on which the CloudWatch Logs, CloudWatch Alarms
  and SNS service principals can be authorized. AWS-managed keys cannot carry
  those grants, which would leave alarm delivery silently broken. (ADR-0010)
- Both Trivy suppressions in `bootstrap/state-backend` were confirmed to match
  their intended rules and now carry a rationale and a revisit trigger inline.
- Ingest queue and DLQ deny every non-TLS request through their queue
  policies (`aws:SecureTransport = false`), and the DLQ accepts redrives only
  from the ingest queue (`byQueue`). The queue policies grant no access; all
  positive access comes from the producer and consumer roles' identity
  policies.
- The cold-storage bucket denies every non-TLS request
  (`aws:SecureTransport = false`), blocks all public access, blocks SSE-C
  uploads and grants nothing in its bucket policy; all positive access comes
  from the ingest role. The hot table and the bucket are protected against
  `terraform destroy` in production (deletion protection on, `force_destroy`
  off), enforced by a root validation rather than by convention.
- Both alert topics are encrypted with the pipeline key and deny every non-TLS
  publish. Neither topic policy grants anything to a wildcard principal: the
  ingest Lambda is authorized through its own IAM policy, and CloudWatch only
  on the operations topic, constrained by `aws:SourceAccount` and an `ArnLike`
  condition on alarm ARNs in this account and region. The fire-risk payload
  carries device coordinates, which is why that topic is CMK-encrypted and
  subscribable by nobody outside the account.
- Recipient email addresses never reach an output, a resource address or a
  `for_each` key. They remain in state in clear text, as Terraform stores every
  value, and `terraform show -json` prints them: `tfplan` and `tfplan.json`
  stay out of version control.
- The IoT fleet client's private key is generated on the operator's machine,
  in an owner-only directory outside both repositories; Terraform receives only
  the CSR, so state holds public material alone (CSR and certificate). The
  certificate is attached exclusively to one Thing and the policy pins the MQTT
  client ID to that Thing's name. The device policy grants no subscribe,
  receive or retained publish.
- Both topic-rule roles trust `iot.amazonaws.com` only for this account and
  this rule (`aws:SourceAccount` + `aws:SourceArn`), closing the
  cross-service confused-deputy path.
- The ingest execution role carries one statement per service path, each
  scoped to a single ARN: the queue (receive, delete, get attributes), the hot
  table (`PutItem` only), `telemetry/*` in the cold bucket (`PutObject` only),
  the fire-alert topic (`Publish` only), its own log group's streams, and the
  pipeline key with only the KMS actions each path needs. No AWS managed
  policies (both Lambda-SQS ones grant logs actions on `*`), no
  `logs:CreateLogGroup`, no `kms:DescribeKey`, no X-Ray wildcard. The function's
  environment variables and its log group are encrypted with the pipeline key.
  The `kms:ViaService` and encryption-context conditions are applied in a
  second step, after the unscoped path is proven at runtime.
- The key policy's `AllowCloudWatchAlarms` statement moves from
  `StringEqualsIfExists aws:SourceAccount` to `StringEquals aws:SourceAccount`
  plus `ArnLike aws:SourceArn` on alarm ARNs in this account and region, the
  confused-deputy pattern AWS documents for service principals on encrypted
  SNS topics. Applied only after a real alarm proved the path with the
  previous statement, and re-proven with a second alarm. (ADR-0010, ADR-0021)
- Every third-party GitHub Action is pinned to a full commit SHA, with the
  version in a comment, instead of a mutable tag, the vector of the
  `tj-actions/changed-files` (CVE-2025-30066) and Trivy (GHSA-69fq-xp46-6x23)
  compromises. Only first-party actions are used (`actions/*`,
  `hashicorp/setup-terraform`). (ADR-0022)
- CI binaries are verified against SHA-256 hashes committed in
  `scripts/tooling/checksums.txt`, so a release whose assets and checksums
  file were both replaced still fails to install. New versions are adopted
  after a 14-day cooldown. (ADR-0022)
- A plan, state, tfvars, backend configuration, CSR or key tracked in git
  fails CI (`make guard`), so a saved plan with sensitive values in clear text
  cannot be merged even when forced past `.gitignore`. Pushing the branch
  already publishes it; `.gitignore` remains the prevention. (debt #41)
- Secret scanning covers every commit in the history, so a secret removed in a
  later commit of the same pull request is still caught before it reaches
  `develop`.
