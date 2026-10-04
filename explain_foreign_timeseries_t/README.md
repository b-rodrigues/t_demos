# explain foreign_meta — Time-Series Facts Demo

End-to-end validation of `explain(p.node).foreign_meta` time-series facts
on ARIMA nodes after a real pipeline build. The pipeline builds four
independent model nodes:

- **`r_arima`** (R) — seasonal `arima` on `AirPassengers`.
- **`py_arima`** (Python) — `statsmodels` ARIMA(1, 0, 0) on 24 points.
- **`r_hw`** (R) — `HoltWinters` on `AirPassengers`.
- **`r_ts`** (R) — `AirPassengers` as a `ts` object.
- **`jl_sarima`** (Julia) — `StateSpaceModels` seasonal SARIMA.

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `task`, `order`, `seasonal_order`, `n_obs`, and fit metrics through
`check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_arima` | `task == "time_series"`, `order == [1, 1, 1]`, `seasonal_order` has 4 entries, `n_obs > 100`, `loglik` present |
| `py_arima` | `task == "time_series"`, `order == [1, 0, 0]`, `n_obs == 24`, `aic` present |
| `r_hw` | `task == "time_series"`, smoothing `alpha` and `sse` present |
| `r_ts` | `kind == "series"`, `n_obs == 144` |
| `jl_sarima` | `task == "time_series"`, `order == [1, 1, 1]`, `loglik` present |

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python nodes,
and `explain(p.node)` resolves it through build logs in a fresh process.
Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```
