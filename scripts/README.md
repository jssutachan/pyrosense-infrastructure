# Scripts

Operational and development utilities.

## Conventions

- Each script is executable, has a shebang, and fails fast:
  `set -euo pipefail` for shell.
- Each script prints usage when invoked with `-h`.
- Scripts are invoked through `make` targets whenever they are part of a
  routine workflow. The Makefile is the entry point; scripts are the
  implementation.
- No credentials, account IDs or endpoints are hardcoded. Values come from
  the environment or arguments.

## Not here

Anything a Terraform resource should own. A script that provisions
infrastructure is a gap in the IaC coverage, not a utility.