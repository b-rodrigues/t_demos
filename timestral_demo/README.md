# timestral_demo

A **T** demonstration project benchmarking **Timestral** (Mistral AI's open-weight time-series foundation models: `mistralai/Timestral-5M` and `mistralai/Timestral-209M`) against a classical **R ARIMA** model on macroeconomic data (US Consumer Price Index, CPIAUCSL from FRED).

## Benchmark Overview

- **Dataset**: Monthly US Consumer Price Index (CPIAUCSL), 2010–2024.
- **Task**: Out-of-sample 12-month ahead inflation forecasting (test window: 2024-01 to 2024-12).
- **Models**:
  - `R Tuned SARIMA / ARIMA`: Fit in R via `forecast::auto.arima(..., seasonal = TRUE)`. Because the CPI series is already seasonally adjusted by the Bureau of Labor Statistics, `auto.arima` selects non-seasonal $(0, 2, 2)$ with $(0, 0, 0)_{12}$, making SARIMA and ARIMA identical.
  - `Timestral-5M`: 5M-parameter foundation model running lightweight zero-shot CPU inference.
  - `Timestral-209M`: 209M-parameter foundation model running zero-shot CPU inference.
- **Evaluation Metrics**: Root Mean Squared Error (RMSE) and Mean Absolute Error (MAE).
- **Report**: Generated Quarto document (`src/report.qmd`) in French compiling metrics and analyzing model trade-offs.

## Getting Started

1. Download the pre-trained model weights (locally stored, not tracked in Git):
```bash
./download_models.sh models
```

2. Enter the reproducible environment:
```bash
nix develop
```

3. Run the pipeline:
```bash
t run src/pipeline.t
```
