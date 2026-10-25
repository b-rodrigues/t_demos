# PMML Scoring Smoke Test

End-to-end smoke test for JPMML scoring with the JARs that `t-lang` ships.

The demo trains one model in R (`randomForest`) and one in Python
(`statsmodels` OLS), exports both to PMML, and scores them in a T node with
`predict()`. Every T score is compared with the native prediction from the
runtime that trained the model, so a working score is proven to be a real
evaluation, not a placeholder.

## What is exercised

| Path | Check |
|:---|:---|
| R -> PMML (`r2pmml`) | `rf_model_r` builds; T scores all 32 rows with no NA |
| Python -> PMML (`jpmml-statsmodels`) | `ols_model_py` builds using the shipped JAR |
| JPMML evaluator (`jpmml-evaluator`) | `predict()` returns 32 values that match R and Python |
| Node environment | `verify_node` runs inside the Nix derivation (`T_JPMML_*_JAR` set there) |
| Project shell | `src/verify.t` scores the same artifacts in a fresh process, resolving the JAR and the JVM from the shell |

Both models are deterministic (`set.seed(42)`, closed-form OLS), so CI can
assert exact parity within `1e-6`.

## Why a demo instead of a unit test

The JARs only exist inside the `t-lang` Nix package, and PMML scoring shells
out to a JVM. Unit tests cannot prove that the packaged `t` finds
`share/java/jpmml-evaluator.jar`, that the converter finds
`jpmml-statsmodels.jar`, or that a `java` executable is reachable. That needs a
real `t update` + `t run` in a project shell.

## Usage

```bash
t update
t run src/pipeline.t
t run --unsafe src/verify.t
```

`jre` in `[additional-tools]` supplies the JVM. No Maven resolution happens at
build time: the JARs are vendored in the `tlang` repository and copied into the
`t-lang` output.
