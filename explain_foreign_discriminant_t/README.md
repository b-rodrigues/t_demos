# explain foreign_meta — Discriminant Facts Demo

End-to-end validation of `explain(p.node).foreign_meta` discriminant
facts after a real pipeline build. The pipeline builds five independent
nodes:

- **`r_lda`** (R) — `MASS::lda`, iris, 3 classes.
- **`r_polr`** (R) — `MASS::polr`, housing data.
- **`r_multinom`** (R) — `nnet::multinom`, iris, 3 classes.
- **`py_gmm`** (Python) — `GaussianMixture`, 2 components.
- **`py_grid`** (Python) — `GridSearchCV` over `LogisticRegression`.

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `task`, classes, features, and fit metrics through `check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_lda` | `task == "classification"`, 3 classes, 4 features |
| `r_polr` | `task == "classification"`, 3 classes, deviance present |
| `r_multinom` | `task == "classification"`, 3 classes |
| `py_gmm` | `task == "density"`, `n_components == 2`, `lower_bound` present |
| `py_grid` | `task == "classification"`, `best_score` present |

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python nodes,
and `explain(p.node)` resolves it through build logs in a fresh process.
Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```
