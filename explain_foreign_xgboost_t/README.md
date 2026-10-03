# explain foreign_meta — XGBoost Facts Demo

End-to-end validation of `explain(p.node).foreign_meta` boosted-tree facts
on xgboost nodes after a real pipeline build. The pipeline builds two
independent booster nodes:

- **`r_xgb`** (R) — native `xgb.train` booster, 5 rounds, agaricus data.
- **`py_xgb`** (Python) — native `xgb.train` booster, 5 rounds.

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `task`, `n_rounds`, and `n_features` through `check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_xgb` | `kind == "model"`, `n_rounds == 5` |
| `py_xgb` | `task == "classification"`, `n_rounds == 5`, `n_features == 1` |

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python nodes,
and `explain(p.node)` resolves it through build logs in a fresh process.
Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```
