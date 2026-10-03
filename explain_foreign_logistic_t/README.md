# explain foreign_meta — Logistic Facts Demo

End-to-end validation of `explain(p.node).foreign_meta` logistic-regression
facts on classification nodes after a real pipeline build. The pipeline
builds three independent logistic models:

- **`r_glm`** (R) — `glm(am ~ wt, mtcars, family = binomial)`.
- **`py_glm`** (Python) — `LogisticRegression`, 2 classes.
- **`jl_glm`** (Julia) — `GLM.glm` with `Binomial()`/`LogitLink()`.

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `task`, `target`, `formula`, and fit metrics through `check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_glm` | `task == "classification"`, `target == "am"`, `formula == "am ~ wt"`, `n_obs == 32`, `aic` present |
| `py_glm` | `task == "classification"`, 2 classes |
| `jl_glm` | `task == "classification"`, `target == "y"`, `deviance` present |

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python/Julia
nodes, and `explain(p.node)` resolves it through build logs in a fresh
process. Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```
