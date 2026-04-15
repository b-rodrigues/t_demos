# Pipeline Lens Orchestration Demo

This demo showcases the powerful new integration between Tlang **Lenses** and **Pipelines**. 

Historically, pipelines were treated as immutable specifications. Now, you can use lenses to surgically inspect and modify pipeline state at runtime—enabling advanced orchestration patterns like dynamic `noop` toggling, runtime swapping, and multi-node inspection.

## Key Features Demonstrated

1.  **`node_meta_lens(name, field)`**: Focuses on internal node properties like `runtime`, `noop`, `serializer`, and `deserializer`.
2.  **`filter_lens(predicate)` on Pipelines**: Dynamically focuses on sets of nodes based on their metadata (e.g., "all R nodes" or "all nodes currently marked as noop").
3.  **`get(pipe, lens)` unification**: Uses a single polymorphic primitive to retrieve both node values and node metadata.

## Run

```bash
t main.t
```
