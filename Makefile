# Single entry point for the repository. Run `make help` for the catalog.
#
# Required tools (see README for installation):
#   terraform >= 1.11   tflint >= 0.50   trivy   pre-commit   gitleaks
#
# `make check` runs exactly what CI runs: verification only, no file changes.

TFVARS         ?= demo.tfvars
BACKEND_CONFIG := config/backend.hcl

# Additional Terraform roots validated alongside the main one.
BOOTSTRAP_ROOTS := bootstrap/state-backend

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
	if [ -n "$$missing" ]; then echo "missing:$$missing"; exit 1; fi
	@echo "all tools present:"
	@terraform version | head -1
	@tflint --version | head -1
	@trivy --version | head -1
	@pre-commit --version

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

sec: ## Scan for misconfigurations and hardcoded secrets
	trivy config --severity HIGH,CRITICAL .
	gitleaks detect --no-git --redact

check: fmt-check validate lint sec ## Run the full gate

## ------------------------------------------------------------------ python
# Not part of `check` yet: src/ and tests/ hold no Python code.
# ruff, mypy and pytest join the gate with the ingest Lambda.

py-lint: ## Lint Python
	ruff check src tests

py-type: ## Type-check Python
	mypy

py-test: ## Run the Python test suite
	pytest

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
