# Nix Orchestration Stress Test (`nix_orchestration_stress_t`)

This demo showcases and stress-tests the new native Nix orchestration capabilities introduced in T-Lang.

## Tested Features

1. **Dry-Run Mode (`dry_run`)**: Triggering dry runs through both `populate_pipeline()` and `build_pipeline()` to ensure they correctly query `nix-build` and compile the execution plan into a standard T-Lang `DataFrame`.
2. **Granular Target Compilation (`targets`)**: Selecting specific nodes to build selectively.
3. **Advanced Nix Parameter Passing**: Passing custom Nix execution constraints (`max_jobs`, `cache`, `verbose`) cleanly through the dynamic built-in engine.
4. **Early Validation Protection**: Compile-time check of target and force node lists in the OCaml engine to instantly warn about nonexistent nodes before initiating any process spawns.

## Running Locally

To run the pipeline and all integration assertions, execute:
```bash
t run src/pipeline.t
```
