# T-Lang Demo: Data Quality Guardrails

This project demonstrates how to implement a robust **Data Guardrail** pipeline using T-Lang and Nix.

## Overview

The pipeline (`src/pipeline.t`) processes a "dirty" dataset and applies three automated quality gates (guardrails):

1.  **Range Check**: Verifies that numeric values (age, scores) are within logical bounds.
2.  **Date Consistency**: Ensures relational integrity between dates (e.g., login must be after signup).
3.  **Missingness Check**: Validates that critical fields (ID, Email) do not contain null values.

## Key Features

- **Polyglot Nodes**: Uses R for synthetic data generation and T-Lang for validation and analytics.
- **Nix-Based Isolation**: Each node runs in a hermetic environment with its own dependencies (R, Arrow, etc.).
- **Soft Error Handling**: T-Lang captures assertion failures as structured error objects within the pipeline, allowing for detailed diagnostic inspection without crashing the orchestration script.
- **Integrated Introspection**: Uses `read_node()` to extract diagnostics and `explain()` to present human-readable failure reasons.

## How to Run

Ensure you have Nix installed and run:

```bash
nix run github:b-rodrigues/tlang -- run src/pipeline.t --unsafe
```

## Expected Behavior

The pipeline is designed to **fail** its guardrails because the input data contains deliberate errors:
- A negative age (-5).
- A score > 100 (150).
- A login date before signup.
- A missing email address.

The console output will show the build status of each node and a summary of the guardrail failures, demonstrating how T-Lang acts as a gatekeeper for data quality.
