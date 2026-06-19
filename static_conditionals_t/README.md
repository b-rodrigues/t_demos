# Static Conditionals Demo

Demonstrates `node_when` and `node_fork` for conditionally including nodes in a pipeline **at construction time**. Conditions are evaluated before any build starts, preserving Nix's static DAG requirement.

## Usage

```bash
# Run with default env (CI=0 or unset)
t run src/pipeline.t

# Run as if in CI
CI=1 t run src/pipeline.t
```

## What it shows

1. **`node_when(condition, value)`** — include a node only when `condition` is truthy. Useful for gating expensive analysis steps behind an env var like `CI`.
2. **`node_fork(cond1, val1, cond2, val2, ..., .default = val)`** — select the first matching alternative. Falls back to `.default` if provided, otherwise the node is excluded.
3. **Error handling** — clear messages for misuse (odd argument count, etc.).
