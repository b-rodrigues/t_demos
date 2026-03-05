# Skip Nodes Demo

This demo focused on skipping heavy nodes during pipeline builds using `noop = true`, as described in [pipeline_tutorial.md](file:///home/brodrigues/Documents/repos/tlang/docs/pipeline_tutorial.md#L528-551).

## Features
- Using `noop = true` in `node()` and language-specific wrappers.
- Propagating `noop` status through the dependency graph.
- Inspecting `noop` status with `select_node`.
- Building a pipeline with skipped nodes.

## Running
```bash
t run src/skip_demo.t
```
