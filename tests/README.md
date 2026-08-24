# Tests

Automated tests for the Python source under `src/`.

## Conventions

- pytest. `testpaths` is configured in `pyproject.toml`.
- Test layout mirrors `src/`.
- AWS calls are mocked. The suite runs offline, with no credentials and no
  billable resources.
- Tests are part of the definition of done for a change, not a follow-up task.

## Not here

Terraform validation. Static analysis of infrastructure code runs through
`make lint` and `make sec`, not through pytest.