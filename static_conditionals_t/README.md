# Static Conditionals Demo

This demo demonstrates static conditionals (`node_when` and `node_fork`) for pipeline node construction. These functions are evaluated at **pipeline construction time**, preserving Nix's static DAG requirement — the condition is checked before the build, not during it.

## Features

- `node_when(condition, value)` — includes a node only if `condition` is truthy
- `node_fork(cond1, val1, cond2, val2, ..., .default = NA)` — selects the first node whose condition is truthy
- Error handling: unexpected named args, odd positional arg counts

## Running

```bash
t run src/pipeline.t
```
