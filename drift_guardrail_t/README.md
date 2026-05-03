# drift_guardrail_t

A T data analysis project.

## Getting Started

1. Enter the reproducible environment:

```bash
nix develop
```

2. Run the analysis:

```bash
t run src/pipeline.t
```

3. Start the interactive REPL:

```bash
t repl
```

## Project Structure

- `src/` — T source files
- `data/` — Input data files
- `outputs/` — Generated outputs
- `tests/` — Test files

## Dependencies

Dependencies are managed **declaratively** via `tproject.toml`.

To add a new dependency:

1. Add it to the `[dependencies]` section of `tproject.toml`:
   ```toml
   [dependencies]
   my-pkg = { git = "https://github.com/user/my-pkg", tag = "v0.1.0" }
   ```
2. Run `nix develop` — the package is automatically fetched
3. Commit `tproject.toml`

No imperative install commands — `flake.nix` reads `tproject.toml` directly.

## Editor Support

This project includes support for the **T Language Server (LSP)**.

1. Configure your editor following the [Editor Support Guide](https://tstats-project.org/editors.html).
2. Always launch your editor from within the `nix develop` environment (or use `direnv`).

## CI Simulation: Drift & Recovery

This project includes a special GitHub Action ([simulate_drift_recovery.yml](.github/workflows/simulate_drift_recovery.yml)) that demonstrates a realistic data observability workflow:
1. **Initial PASS**: Verifies the pipeline is healthy (Threshold = 15.0).
2. **Detected DRIFT**: Tightens the threshold to 2.0 via `sed`, triggering an intentional guardrail failure.
3. **RECOVERY**: Updates the threshold to 20.0 (simulating a policy adjustment), and verifies the pipeline returns to a healthy state.

You can trigger this manually via the "Actions" tab in GitHub to see the "human-in-the-loop" simulation in the logs.

## License

EUPL-1.2
