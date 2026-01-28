# py-stack-linter Composite Action

A GitHub composite action that bundles Python linting checks: Ruff code analysis, file structure validation, and Dockerfile linting.

## Usage

```yaml
- name: Run py-stack-linter
  uses: ross412/py-stack-linter/.github/actions/py-stack-linter@main
  with:
    python-version: "3.11"
    ruff-version: "latest"
    run-structure-lint: true
    run-dockerfile-lint: true
    trusted-registries: "my-registry.com,another-registry.io"
```

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `python-version` | Python version for linting | `"3.11"` |
| `ruff-version` | Ruff version to use | `"latest"` |
| `run-structure-lint` | Enable file structure linting | `"true"` |
| `run-dockerfile-lint` | Enable Dockerfile linting | `"true"` |
| `dockerfile-glob` | Glob pattern for finding Dockerfiles | `"**/Dockerfile"` |
| `trusted-registries` | Comma-separated list of trusted registries for hadolint | `""` |

## Components

The action runs the following checks:

- **Ruff**: Python code linting using the shared `ruff.toml` configuration
- **Structure Linter**: Validates file/directory naming conventions and structure
- **Hadolint**: Docker image linting with configurable trusted registries

All checks run with `continue-on-error: true` and the action fails if any check fails (unless skipped).
