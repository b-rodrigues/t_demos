# explain foreign_meta — Forest Facts Demo

End-to-end validation of `explain(p.node).foreign_meta` forest facts on
random forest nodes after a real pipeline build. The pipeline builds three
independent forest nodes:

- **`r_forest`** (R) — `randomForest(mpg ~ ., mtcars)` regression, 50 trees.
- **`py_forest`** (Python) — `RandomForestClassifier`, 10 trees.
- **`jl_forest`** (Julia) — `DecisionTree.build_forest` classifier, 10 trees.

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `task`, `n_trees`, `n_obs`, `n_features`, and accuracy metrics
through `check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_forest` | `task == "regression"`, `n_trees == 50`, `n_obs == 32`, `n_features == 10`, `r_squared > 0.8` |
| `py_forest` | `task == "classification"`, `n_features == 2`, 2 classes |
| `jl_forest` | `task == "classification"`, `n_trees == 10`, `n_features == 2` |

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python/Julia
nodes, and `explain(p.node)` resolves it through build logs in a fresh
process. Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```
