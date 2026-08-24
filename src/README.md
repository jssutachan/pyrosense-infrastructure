# Application Source

Python source for the compute layer, primarily AWS Lambda handlers.

## Conventions

- Python 3.12.
- One package per Lambda function.
- Handlers stay thin: parse, delegate, return. Business logic lives in
  importable modules so it can be tested without a Lambda runtime.
- Pydantic models at service boundaries only. Internal objects use
  dataclasses.
- Linting, formatting and type checking are configured in `pyproject.toml`
  at the repository root. Ruff and mypy run in strict mode.

## Not here

Infrastructure. Packaging and deployment of this code is described by the
Terraform modules that consume it.
