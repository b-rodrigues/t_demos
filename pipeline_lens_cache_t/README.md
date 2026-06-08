# Pipeline Lens Cache Demo

This demo verifies that in-memory node values set via pipeline lenses are
correctly scoped by pipeline identity. Key invariants tested:

1.  **Lens set + read_node contract**: `set(p, node_lens("a"), 10)` then
    `read_node(p2.a)` returns `10`.
2.  **Direct access preserves VComputedNode**: After a lens set, `p2.a`
    returns a `VComputedNode` (metadata), not the raw value — the value
    lives in the cache and is retrieved by `read_node`.
3.  **Cross-pipeline isolation**: Two pipelines with a node named `x` can
    independently lens-set values without contaminating each other.
4.  **Add missing node**: `set` on a non-existent node adds a placeholder
    `VComputedNode` so `get` can retrieve the cached value.
5.  **Missing node returns NA**: `get(p, node_lens("missing"))` on an
    unmodified pipeline returns `NA`.

## Run

```bash
t run src/pipeline.t
```
