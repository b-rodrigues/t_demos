# explain foreign_meta — Classic Stats Demo

End-to-end validation of `explain(p.node).foreign_meta` facts on
classic-stats objects after a real pipeline build. The pipeline builds
seven independent nodes:

- **`r_nls`** (R) — `nls` nonlinear fit.
- **`r_htest`** (R) — `t.test` result.
- **`r_fitdistr`** (R) — `MASS::fitdistr` Poisson fit.
- **`r_loess`** (R) — `loess` smoother.
- **`py_ets`** (Python) — `ExponentialSmoothing` with trend.
- **`py_pipe`** (Python) — scaler plus logistic `Pipeline`.
- **`py_sparse`** (Python) — scipy sparse identity matrix.

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `kind`, `task`, `method`, formulas, and metrics through `check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_nls` | `task == "regression"`, formula, 2 params, `sigma` present |
| `r_htest` | `kind == "test"`, Welch method, `p_value` present |
| `r_fitdistr` | `n_obs == 100`, `loglik` present |
| `r_loess` | `task == "regression"`, `span` present |
| `py_ets` | `task == "time_series"`, `aic` present |
| `py_pipe` | `task == "classification"` |
| `py_sparse` | `kind == "matrix"`, `dimensions == [3, 3]`, `nnz == 3` |

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python nodes,
and `explain(p.node)` resolves it through build logs in a fresh process.
Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```
