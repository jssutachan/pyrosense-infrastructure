# Single entry point for the repository. Run `make help` for the catalog.
#
# Tool versions are pinned in .tool-versions (binaries and Python) and
# requirements-dev.txt (Python packages). `make tools` checks that what is
# installed matches the pins; scripts/tooling/install-tool.sh installs them.
#
# `make check` is the full local gate: verification only, no file changes.
# CI (.github/workflows/ci.yml) runs the same targets, split into jobs.

# Every recipe runs in bash with errexit, nounset and pipefail: a failing
# command anywhere in a recipe, including the left side of a pipe, fails the
# target instead of being masked by the next command.
SHELL       := bash
.SHELLFLAGS := -euo pipefail -c

TFVARS         ?= demo.tfvars
BACKEND_CONFIG := config/backend.hcl

# Additional Terraform roots validated alongside the main one.
BOOTSTRAP_ROOTS := bootstrap/state-backend

# Python tools come from the project virtualenv when it exists (local runs,
# no need to activate it first) and from PATH otherwise (CI installs them into
# the runner's Python). Calling the executables directly avoids relying on
# `source .venv/bin/activate` having been run in the current shell.
VENV   ?= .venv
PY_BIN := $(if $(wildcard $(VENV)/bin/python),$(VENV)/bin/,)

# Every directory with Python the gate must cover. Keep in sync with
# [tool.mypy] files in pyproject.toml: a path missing here is a false green.
PY_PATHS := src tests scripts

.DEFAULT_GOAL := help

.PHONY: help tools setup hooks update-hooks fmt fmt-check init validate lint-init lint \
        sec sec-config secrets guard ci-lint py-fix py-lint py-type py-test check \
        tf-init plan apply destroy clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

## ------------------------------------------------------------------- setup

tools: ## Verify installed tools match the pinned versions
	@echo "pinned toolchain (.tool-versions):"
	@scripts/tooling/check-tool-versions.sh "$(PY_BIN)"
	@missing=""; \
	for t in pre-commit; do \
		command -v $$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	for t in ruff mypy pytest; do \
		command -v $(PY_BIN)$$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	if [ -n "$$missing" ]; then echo "missing:$$missing"; exit 1; fi
	@echo "python packages: see requirements-dev.txt"

setup: tools hooks ## Prepare a fresh clone for development
	@echo "ready. run 'make check' to verify the gate"

hooks: lint-init ## Install the git hook and download TFLint plugins
	pre-commit install

update-hooks: ## Bump pre-commit hook revisions (produces a reviewable diff)
	pre-commit autoupdate

## ------------------------------------------------------------- quality gate

fmt: ## Format Terraform code in place
	terraform fmt -recursive

fmt-check: ## Verify formatting without modifying any file
	terraform fmt -check -recursive

# -lockfile=readonly: the gate verifies .terraform.lock.hcl and never rewrites
# it. A provider added without updating the committed lock fails here instead
# of being resolved silently.
init: ## Initialise every Terraform root without touching the backend
	terraform init -backend=false -input=false -lockfile=readonly
	@for dir in $(BOOTSTRAP_ROOTS); do \
		terraform -chdir=$$dir init -backend=false -input=false -lockfile=readonly; \
	done

validate: init ## Validate every Terraform root against the provider schema
	terraform validate
	@for dir in $(BOOTSTRAP_ROOTS); do \
		terraform -chdir=$$dir validate; \
	done

lint-init: ## Download the TFLint plugins pinned in .tflint.hcl
	tflint --init --config "$(CURDIR)/.tflint.hcl"

lint: lint-init ## Lint Terraform with TFLint
	tflint --recursive --config "$(CURDIR)/.tflint.hcl"

sec: sec-config secrets ## Scan for misconfigurations and hardcoded secrets

# Two Trivy runs, both with the tfvars loaded so every expression is evaluated
# with real values. The first is informational: every severity, never fails.
# The second is the gate (scripts/tooling/trivy-gate.sh): HIGH/CRITICAL
# findings or any file Trivy could not parse fail the target.
#
# trivy.yaml sets skip-check-update, so Trivy uses the checks embedded in the
# pinned binary. A checks bundle cached by an earlier, unpinned run would take
# precedence over the embedded one; removing it first keeps local runs on the
# same rules as CI.
sec-config: ## Scan Terraform for misconfigurations (Trivy)
	trivy clean --checks-bundle
	trivy config . --tf-vars $(TFVARS)
	scripts/tooling/trivy-gate.sh $(TFVARS)

# `gitleaks git` scans every commit, not only the files on disk: a secret
# added in one commit and deleted in the next is still published in a public
# repository's history. CI checks out the full history for this target.
secrets: ## Scan the git history for hardcoded secrets (gitleaks)
	scripts/tooling/gitleaks-gate.sh

guard: ## Fail on tracked plans, state, tfvars or keys, and on real values in templates
	@scripts/tooling/guard.sh

ci-lint: ## Lint the GitHub Actions workflows (actionlint)
	actionlint

py-fix: ## Fix and format Python in place (used by the pre-commit hook)
	$(PY_BIN)ruff check --fix $(PY_PATHS)
	$(PY_BIN)ruff format $(PY_PATHS)

py-lint: ## Lint and format-check Python (no file changes)
	$(PY_BIN)ruff check $(PY_PATHS)
	$(PY_BIN)ruff format --check $(PY_PATHS)

py-type: ## Type-check Python
	$(PY_BIN)mypy

# --cov makes pytest-cov enforce fail_under from pyproject.toml: without it
# the 90 % branch-coverage floor is configured but never applied.
py-test: ## Run the Python test suite with the coverage floor
	$(PY_BIN)pytest --cov --cov-report=term-missing

check: guard fmt-check validate lint sec ci-lint py-lint py-type py-test ## Run the full gate

## -------------------------------------------------------------- terraform ops

tf-init: ## Initialise Terraform with the remote backend
	terraform init -backend-config=$(BACKEND_CONFIG)

plan: ## Show the execution plan (TFVARS=prod.tfvars for the cost model)
	terraform plan -var-file=$(TFVARS)

apply: ## Apply the configuration
	terraform apply -var-file=$(TFVARS)

destroy: ## Destroy all managed infrastructure
	terraform destroy -var-file=$(TFVARS)

clean: ## Remove local Terraform and Python caches
	rm -rf .terraform/ .pytest_cache/ .ruff_cache/ .mypy_cache/
	find . -type d -name '__pycache__' -prune -exec rm -rf {} +
