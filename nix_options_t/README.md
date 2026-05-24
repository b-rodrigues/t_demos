# Nix Options Demo

This demo exercises the unified `nix_options` dictionary parameter for T-Lang pipeline functions:
- `populate_pipeline`
- `build_pipeline`
- `pipeline_run`
- `t_make`

It verifies that orchestration parameters (`max_jobs`, `max_cores`, `targets`, `force`, `dry_run`, and `cache`) are correctly validated, parsed, and propagated.
