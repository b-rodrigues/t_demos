# explain foreign_meta — Model Facts Demo

End-to-end validation of `explain(p.node).foreign_meta` model facts on
regression nodes after a real pipeline build. The pipeline builds two
independent model nodes:

- **`r_fit`** (R) — `lm(mpg ~ wt + hp, data = mtcars)`.
- **`py_fit`** (Python) — `LinearRegression` on 3 observations, 1 feature.

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `task`, `target`, `formula`, `n_obs`, `n_features`, and fit metrics
through `check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_fit` | `task == "regression"`, `target == "mpg"`, `formula == "mpg ~ wt + hp"`, `n_obs == 32`, `n_features == 2`, `r_squared > 0.8` |
| `py_fit` | `task == "regression"`, `n_features == 1` |

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python nodes,
and `explain(p.node)` resolves it through build logs in a fresh process.
Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```
