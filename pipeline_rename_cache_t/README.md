# Pipeline Rename Cache Demo

This demo verifies that in-memory node values correctly follow their node
through a `rename_node` operation.

When a node is renamed, its cached value must be migrated from
`(old_p_exprs, old_name)` to `(new_p_exprs, new_name)` so that subsequent
`read_node` calls on the renamed node find the cached value.

Key invariants tested:

1.  **Cache migration on rename**: Lens set value on node `a`, rename to
    `a_v2`, `read_node(p2.a_v2)` returns the cached value.
2.  **Old name resolution**: After rename, `read_node(p2.a)` returns an error
    (node no longer exists under the old name).
3.  **Cache after rename**: Lens set on renamed node, verify the value is
    stored under the new identity.

## Run

```bash
t run src/pipeline.t
```
