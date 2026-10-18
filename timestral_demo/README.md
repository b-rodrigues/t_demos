# timestral_demo

A **T** demonstration project benchmarking **Timestral** (Mistral AI's open-weight time-series foundation models: `mistralai/Timestral-5M` and `mistralai/Timestral-209M`) against a classical **R ARIMA** model on macroeconomic data (US Consumer Price Index, CPIAUCSL from FRED).

## Benchmark Overview

The demonstration evaluates **Timestral-5M** and **Timestral-209M** against standard R econometric baselines across three distinct paradigms:

1. **Study 1: Canonical Univariate Inflation Benchmark (CPI)**:
   - Data: `CPIAUCSL` (2010–2024, FRED).
   - Models: `forecast::auto.arima` (optimal $\text{ARIMA}(0, 2, 2)$) vs Timestral-5M vs Timestral-209M.
   - Finding: SARIMA and ARIMA are identical because the series is already seasonally adjusted by BLS; Timestral-5M beats ARIMA.

2. **Study 2: Multi-Sector Retail Sales & Hierarchical Structure (Proposition 1)**:
   - Data: US Census Bureau Monthly Retail Trade Survey (`RSAFS`, `RSMVPD`, `RSFSDP`, `RSCCAS`, `RSNSR`, `RSGMS`).
   - Models: Independent per-sector `auto.arima` and Bottom-Up sum vs batch zero-shot Timestral-5M and 209M.
   - Finding: Timestral-209M dominates volatile sectors (Automotive, E-commerce) while ARIMA performs well on steady non-cyclical food/general retail.

3. **Study 3: Macroeconomic Triad & Monetary Policy Shocks (Proposition 3)**:
   - Data: 25 years (2000–2024) of Inflation (`CPIAUCSL`), Unemployment (`UNRATE`), and Effective Federal Funds Rate (`FEDFUNDS`).
   - Models: Structural Vector Autoregression (`vars::VAR(2)`) and dynamic transfer-function ARIMAX with policy rate vs zero-shot Timestral.
   - Finding: ARIMAX with interest rates excels on inflation, but Timestral crushes statistical models on unemployment by avoiding false rate-shock over-reaction.

- **Quarto Report**: Synthesized French analysis report (`src/report.qmd`) rendered into HTML with `{t}` code blocks.

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
