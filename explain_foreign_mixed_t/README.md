# explain foreign_meta — Mixed-Effects Facts Demo

End-to-end validation of `explain(p.node).foreign_meta` hierarchical facts
on mixed-effects nodes after a real pipeline build. The pipeline builds
two independent mixed models:

- **`r_lmer`** (R) — `lmer(Reaction ~ Days + (Days | Subject), sleepstudy)`.
- **`py_mixed`** (Python) — `MixedLM`, 30 observations in 6 groups.

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `task`, `formula`, `groups`, and fit metrics through `check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_lmer` | `task == "regression"`, full formula with random effects, `n_groups == 18`, `Subject` count, `loglik` present |
| `py_mixed` | `task == "regression"`, `n_groups == 6`, per-group counts, `aic` present |

No Julia node: MixedModels.jl cannot precompile in the pinned Nix
environment, so Julia mixed models stay on the generic probe path.

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python nodes,
and `explain(p.node)` resolves it through build logs in a fresh process.
Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```
