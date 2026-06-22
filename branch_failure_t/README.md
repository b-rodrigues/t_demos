# Branch Failure Recovery Demo

Demonstrates graceful degradation when one branch of a `map_pattern` fails at build time. Each branch runs as an independent Nix derivation, so one crash does not block the others.

## Usage

```bash
t run src/pipeline.t
```

## What it shows

1. **Non-aborting build**: A failing branch does not prevent other branches from building.
2. **Accurate error diagnostics**: `errored_nodes()` returns exactly the failing branch with the original error message.
3. **Selective result access**: Successful branches can still be read with `read_node()`.
4. **Build log transparency**: `build_log_to_frame()` reports all nodes with their status.
