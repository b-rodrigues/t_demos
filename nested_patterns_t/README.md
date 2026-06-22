# Nested Patterns Demo

Demonstrates chained dynamic pattern expansion across multiple pipeline stages:

- **Stage 1**: `map_pattern(groups)` expands groups into 2 base branches.
- **Stage 2**: `cross_pattern(map_pattern(base), map_pattern(adjustments))` crosses the already-expanded base branches with 3 adjustment values, producing 6 final branches.

This exercises the `expanded_map` dependency resolution across stages, topological sort ordering, and cross-pattern-to-map-pattern chaining.

## Usage

```bash
t run src/pipeline.t
```

## What it shows

1. **Chained pattern expansion**: Stage 1's expanded branches feed into Stage 2's pattern.
2. **expanded_map resolution**: `map_pattern(base)` resolves through the previously expanded `base` node.
3. **Architecture verification**: Correct node counts, edge counts, and runtime propagation.
4. **Build verification**: All 6 leaf branches produce correct arithmetic values.
