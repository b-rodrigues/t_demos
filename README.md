# T Language Demos

This repository contains a large collection of demonstration projects for the **T** orchestration engine. The repository currently includes 72 self-contained demos covering polyglot pipelines, serialization and model exchange, diagnostics and recovery, statistical workflows, and reproducible Quarto reporting.

## Key Features Showcased
- **Polyglot Pipelines**: Orchestrating T, R (`rn`), Python (`pyn`), and Shell (`shn`) nodes in a single DAG.
- **First-Class Serializers and Interchange**: Demonstrating `^arrow`, `^csv`, `^json`, `^pmml`, `^onnx`, and custom serializer workflows.
- **Pipeline Metaprogramming**: Exploring pipeline lenses, pipeline operators, dynamic features, node skipping, and multi-input orchestration.
- **Diagnostics and Recovery**: Showcasing guardrails, observability, dependency injection, error propagation, and error recovery patterns.
- **Nix-Powered Reproducibility**: Each project is a self-contained Nix flake with isolated language and tool dependencies.
- **Quarto Integration**: Rendering reports and demo documentation that consume pipeline artifacts via the `tlang` Quarto extension.

## Repository Structure
Each subdirectory is a complete T project with its own `tproject.toml` and pipeline logic.

### Core pipeline and language demos
- `basic_t`, `check_nodes_pipeline_t`, `companion_check_t`, `dynamic_pipeline_operator_t`, `nix_options_t`, `nix_orchestration_stress_t`, `package_manager_functions_t`, `pipeline_functions_t`, `pipeline_ops_t`, `pipeline_lens_orchestration_t`
- `dynamic_features_t`, `secrets_t`, `skip_nodes_t`, `many_inputs_t`, `many_unserialize_t`, `get_sym_demo_t`
- `lens_demo_t`, `deep_data_lenses_t`, `shn_t`, `polyglot_shell_t`, `multi_lang_pipeline_t`, `julia_interop_t`

### Interchange, serialization, and model portability demos
- `arrow_interop_t`, `arrow_source_coverage_t`, `arrow_edge_cases_t`, `custom_polyglot_serializer_t`, `json_interchange_t`, `multi_deserializer_t`, `r_py_json_t`
- `factor_roundtrip_t`, `pmml_interchange_t`, `pmml_julia_r_interop_t`, `pmml_julia_rf_stress_t`, `onnx_exchange_t`, `onnx_classification_t`, `onnx_julia_stress_t`, `onnx_neural_world_age`, `onnx_neuralnet_t`
- `onnx-exchange-deps-inject-test`, `r_py_xgboost_t`, `serializer_stress_test_t`

### Diagnostics, guardrails, and resilience demos
- `data_guardrail_t`, `diff_history_t`, `drift_guardrail_t`, `diagnostics_demo_t`, `env_var_orchestration_t`, `observability_hardening_t`
- `error_propagation_circuit_t`, `error_recovery_t`

### Data wrangling, package comparison, and visualization demos
- `chrono_vs_lubridate_t`, `dplyr_advanced_t`, `stringr_vs_strcraft_t`, `polars_vs_t_t`, `plotting_pipeline_t`, `julia_plotting_t`

### Modeling and comparison demos
- `model_capabilities_demo_t`, `model_comparison_t`, `model_comparison_with_glance_t`, `stats_functions_t`
- `glm_basic_r_t`, `glm_basic_py_t`, `glm_discoveries_t`, `glm_hsb_t`, `glm_titanic_t`, `glm_warpbreaks_t`

### Case studies and end-to-end examples
- `quarto_latex_demo_t`, `quarto_test_t`, `yanai_lercher_2020_t`
- `isl_lab2_boston_t`, `isl_lab4_smarket_t`, `isl_lab5_smarket_lda_t`, `isl_lab10_hitters_t`, `isl_lab12_poly_t`

## Continuous Integration (CI)
All demos in this repository are automatically tested via GitHub Actions. Since T is under active development, the CI is configured to:
1. Run `t update` to sync with the version requested in `tproject.toml`.
2. **Usually override the T version to `main`** to ensure demos stay compatible with the latest development version of the language; branch-specific demos can target a different T branch when they exercise unreleased features.
3. Build and execute the entire DAG to verify serialization and runtime correctness.

## Build Site
The repository includes a `rebuild_demos_site.sh` script that generates a `docs/` site by running each demo, rendering Quarto pages for the pipeline nodes, and assembling a browsable index. The `.github/workflows/build-site.yml` workflow uses that script to rebuild and publish the generated site content.

---
[T Orchestration Engine](https://github.com/b-rodrigues/tlang/)
