# py_uv_workspace_t

Demonstrates UV workspace Python dependency resolver in T pipelines.

## What it tests

- `tproject.toml` with `[py-dependencies].resolver = "uv"` (no `packages` key)
- Python environment built from a UV workspace (`python/` directory with `pyproject.toml` + `uv.lock`)
- Pipeline node with `runtime = Python` using `pandas` from the UV workspace
- Correct computation result verified via assertion

## How to run

```bash
nix develop --command t run src/pipeline.t
```

The pipeline reads `data/scores.csv` with `pandas.read_csv()`, computes the mean of the `score` column, and asserts the result is 87.8.
