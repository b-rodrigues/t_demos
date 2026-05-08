# PMML Julia Random Forest Stress Test

This demo stress-tests Julia's PMML scoring path on a larger synthetic dataset while also exercising Julia-exported PMML for a GLM baseline.

## Features

- **Larger Scoring Workload**: Generates 20,000 synthetic rows for cross-runtime prediction checks.
- **Random Forest PMML Parity**: Trains a random forest in R, exports it as PMML, and compares Julia and T predictions against native R scoring.
- **Julia PMML Baseline**: Exports a Julia GLM as PMML and checks T scoring parity against Julia's native predictions.

## How to run

```bash
nix develop
t update
t run src/pipeline.t
```
