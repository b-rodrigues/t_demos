# Pipeline Operations Demo

This demo showcases advanced pipeline manipulation functions in T, as described in [pipeline_tutorial.md](file:///home/brodrigues/Documents/repos/tlang/docs/pipeline_tutorial.md).

## Features
- Introspection (`pipeline_nodes`, `pipeline_deps`)
- Node Operations (`filter_node`, `select_node`, `mutate_node`, `rename_node`, `arrange_node`)
- Set Operations (`parallel`, `patch`)
- DAG-Aware Transformations (`subgraph`, `prune`, `chain`)
- Validation (`pipeline_validate`)

## Running
```bash
t run src/pipeline_ops.t
```
