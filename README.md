# T Language Demos

This repository contains a collection of demonstration projects for the **T** orchestration engine. Each demo showcases different features of T, including polyglot pipelines, data interchange between R and Python, and Reproducible Quarto reports.

## Key Features Showcased
- **Polyglot Pipelines**: Orchestrating R (`rn`), Python (`pyn`), and Shell (`shn`) nodes.
- **First-Class Serializers**: Using the new `^` prefixed symbols (e.g., `^arrow`, `^csv`, `^json`, `^pmml`) for type-safe data interchange.
- **Nix-Powered Reproducibility**: Each project is a self-contained Nix flake, ensuring that all dependencies (R/Python libraries, compilers) are versioned and isolated.
- **Quarto Integration**: Generating automated reports that consume pipeline artifacts via the `tlang` Quarto extension.

## Repository Structure
Each subdirectory is a complete T project with its own `tproject.toml` and pipeline logic.

- **`basic_t`**: Minimum viable pipeline with R and T nodes.
- **`check_nodes_pipeline_t`**: Comprehensive test of all node types and built-in serializers.
- **`custom_polyglot_serializer_t`**: Defines custom YAML serializers using foreign code snippets.
- **`deep_data_lenses_t`**: Surgical updates to nested dictionaries using path-based lenses.
- **`dynamic_pipeline_operator_t`**: Programmatic manipulation of pipelines as first-class objects.
- **`env_var_orchestration_t`**: Injection of environment variables into R and Python runtimes.
- **`error_propagation_circuit_t`**: Demonstrates error propagation, short-circuiting, and recovery with `match`.
- **`lens_demo_t`**: Demonstrates deep surgical updates to data structures using functional lenses.
- **`many_inputs_t`**: Shows how to handle multiple source files in a single node.
- **`model_comparison_t`**: Parallel training of R and Python models with native PMML evaluation.
- **`r_py_xgboost_t`**: Training XGBoost models in Python and evaluating them in R.
- **`yanai_lercher_2020_t`**: A real-world example of cross-language thresholding and plotting.

## Continuous Integration (CI)
All demos in this repository are automatically tested via GitHub Actions. Since T is under active development, the CI is configured to:
1. Run `t update` to sync with the version requested in `tproject.toml`.
2. **Override the T version to `main`** to ensure all demos remain compatible with the latest development version of the language.
3. Build and execute the entire DAG to verify serialization and runtime correctness.

## Build Site
The `docs/` folder in this repository is built automatically by the `rebuild_demos_site.sh` script, which renders the state of the nodes across all projects into a single documentation site.

---
[T Orchestration Engine](https://github.com/b-rodrigues/tlang/)
