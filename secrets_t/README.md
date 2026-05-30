# Secrets Demo

This demo exercises the v0.52.2 `keep_env` and `sandbox` options inside `nix_options` for T pipeline functions.

## Features Demonstrated

- **`keep_env` (string)**: Pass a single environment variable name through to the Nix sandbox.
- **`keep_env` (list)**: Pass multiple environment variable names through to the Nix sandbox.
- **`sandbox`**: Control the Nix sandboxing policy (`"relaxed"`, `"strict"`, `"none"`).
- **Combined usage**: Use `keep_env`, `sandbox`, `max_jobs`, and `dry_run` together.
- **Node-level verification**: R nodes read the secrets via `Sys.getenv()` and fail if they are missing, proving the secrets actually reach inside the sandbox.

## How It Works

By default, Nix purges all host environment variables during builds to ensure reproducibility.
The `keep_env` option whitelists specific variables (e.g., access tokens, API keys, database
credentials) so they are forwarded into the build sandbox. This is essential for pipelines
that need to authenticate against external services during execution.

The pipeline nodes use `Sys.getenv()` to read the forwarded variables and `stop()` if any
expected secret is missing, providing an end-to-end test that `keep_env` works.

The `sandbox` option controls the isolation level:
- `"strict"` or `true` — full sandbox (default)
- `"relaxed"` — sandbox with network access
- `"none"` or `false` — no sandbox

## Usage

```bash
export MY_SECRET_TOKEN="my-token"
export API_KEY="my-key"
export DB_PASSWORD="my-pass"
export ACCESS_TOKEN="my-access"
t update
nix develop --command t run src/pipeline.t
```
