# Secrets Demo

This demo exercises the v0.52.2 `keep_env` and `sandbox` options inside `nix_options` for T pipeline functions.

## Features Demonstrated

- **`keep_env` (string)**: Pass a single environment variable name through to the Nix sandbox.
- **`keep_env` (list)**: Pass multiple environment variable names through to the Nix sandbox.
- **`sandbox`**: Control the Nix sandboxing policy (`"relaxed"`, `"strict"`, `"none"`).
- **Combined usage**: Use `keep_env`, `sandbox`, `max_jobs`, `targets`, and `dry_run` together.

## How It Works

By default, Nix purges all host environment variables during builds to ensure reproducibility.
The `keep_env` option whitelists specific variables (e.g., access tokens, API keys, database
credentials) so they are forwarded into the build sandbox. This is essential for pipelines
that need to authenticate against external services during execution.

The `sandbox` option controls the isolation level:
- `"strict"` or `true` — full sandbox (default)
- `"relaxed"` — sandbox with network access
- `"none"` or `false` — no sandbox

## Usage

```bash
t update
nix develop --command t run src/pipeline.t
```
