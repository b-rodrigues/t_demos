# Pipeline Global Options Demo

This demo exercises `set_pipeline_global_options()` and its read-back companion
`pipeline_node_options()`, as described in
[pipeline_tutorial.md](file:///home/brodrigues/Documents/repos/tlang/docs/pipeline_tutorial.md).

## Features
- **Unscoped merge**: `functions`, `include`, `env_vars`, and `serializer` defaults
  merged into every node; the original pipeline is left unchanged.
- **`runtimes` scope**: defaults applied only to nodes of a given runtime (`rn` → R).
- **`nodes` scope**: defaults applied only to exact node names.
- **Union scope**: `runtimes` + `nodes` together.
- **Empty-list semantics**: `nodes = []` targets no nodes; combined with `runtimes`
  the runtime's nodes are still targeted.
- **Hard overrides**: `shell` / `shell_args` on a specific node.
- **Read-back**: `pipeline_node_options(p, node)` returns a node's fully resolved
  configuration (runtime, serializer, noop, deps, env_vars, functions, include, shell).
- **Explicit errors**: unknown node names, unmatched runtimes, and unknown arguments
  raise a `TypeError` rather than silently changing nothing.

## Running
```bash
t run src/pipeline.t
```
