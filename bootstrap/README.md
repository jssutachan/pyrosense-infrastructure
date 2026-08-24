# Bootstrap

A standalone Terraform root that provisions the S3 bucket backing the remote
state of the main configuration.

## Why it is separate

The main configuration stores its state in S3, but that bucket has to exist
before `terraform init` can succeed. This is a chicken-and-egg problem, and
isolating it here is the resolution: this root is applied once, with local
state, before anything else.

Its own state file is intentionally small and disposable. Losing it does not
lose the bucket.

## Usage

Applied once, manually, at project setup. Not part of CI/CD. See the ADR
covering the state backend for the full rationale.