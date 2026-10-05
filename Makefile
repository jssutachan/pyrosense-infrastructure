# Single entry point for the repository. Run `make help` for the catalog.
#
# Required tools (see README for installation):
#   terraform >= 1.11   tflint >= 0.50   trivy   pre-commit   gitleaks
#   Python 3.12 with requirements-dev.txt installed (ruff, mypy, pytest)
#
# `make check` is the full local gate: verification only, no file changes.
# CI runs its Python half today; the Terraform half joins CI with the
# Terraform workflow.

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

.DEFAULT_GOAL := help

.PHONY: help tools setup hooks update-hooks fmt fmt-check init validate lint sec \
        py-lint py-type py-test check tf-init plan apply destroy clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

## ------------------------------------------------------------------- setup

tools: ## Verify the required tools are installed
	@missing=""; \
	for t in terraform tflint trivy pre-commit gitleaks; do \
		command -v $$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	for t in ruff mypy pytest; do \
		command -v $(PY_BIN)$$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	if [ -n "$$missing" ]; then echo "missing:$$missing"; exit 1; fi
	@echo "all tools present:"
	@terraform version | head -1
	@tflint --version | head -1
	@trivy --version | head -1
	@pre-commit --version
	@$(PY_BIN)ruff --version

setup: tools hooks ## Prepare a fresh clone for development
	@echo "ready. run 'make check' to verify the gate"

hooks: ## Install the git hook and download TFLint plugins
	pre-commit install
	tflint --init

update-hooks: ## Bump pre-commit hook revisions (produces a reviewable diff)
	pre-commit autoupdate

## ------------------------------------------------------------- quality gate

fmt: ## Format Terraform code in place
	terraform fmt -recursive

fmt-check: ## Verify formatting without modifying any file
	terraform fmt -check -recursive

init: ## Initialise every Terraform root without touching the backend
	terraform init -backend=false
	@for dir in $(BOOTSTRAP_ROOTS); do \
		terraform -chdir=$$dir init -backend=false; \
	done

validate: init ## Validate every Terraform root against the provider schema
	terraform validate
	@for dir in $(BOOTSTRAP_ROOTS); do \
		terraform -chdir=$$dir validate; \
	done

lint: ## Lint Terraform with TFLint
	tflint --recursive --config "$(CURDIR)/.tflint.hcl"

# Two Trivy runs, both with the tfvars loaded so every expression is evaluated
# with real values. The first is informational: it prints findings of every
# severity and never fails. The second is the gate: --exit-code 1 makes HIGH
# and CRITICAL findings fail `make check`. Trivy's exit code defaults to 0,
# so without that flag the scan reports findings and the gate stays green.
sec: ## Scan for misconfigurations and hardcoded secrets
	trivy config . --tf-vars $(TFVARS)
	trivy config . --tf-vars $(TFVARS) --severity HIGH,CRITICAL --exit-code 1
	gitleaks detect --no-git --redact

py-lint: ## Lint and format-check Python (no file changes)
	$(PY_BIN)ruff check src tests
	$(PY_BIN)ruff format --check src tests

py-type: ## Type-check Python
	$(PY_BIN)mypy

py-test: ## Run the Python test suite
	$(PY_BIN)pytest

check: fmt-check validate lint sec py-lint py-type py-test ## Run the full gate

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
