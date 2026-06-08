# Pipeline Equality Demo

This demo verifies the semantics of `==` vs `identical()` on `VComputedNode`
values.

- `==` compares **value** only (ignores pipeline identity metadata).
- `identical()` compares **everything**, including the `cn_p_exprs` field that
  tracks which pipeline a VComputedNode belongs to.

Key invariants tested:

1.  Two structurally identical pipelines: `p1.c == p2.c` → `true` (same value,
    different pipeline identity).
2.  `identical(p1.c, p2.c)` → `false` (different pipeline identity metadata).
3.  After a lens set changes one node: `p1.a == p2.a` → `false` (values now
    diverge).
4.  `identical(p1.a, p2.a)` → `false` (different values AND different identity).
5.  Comparing a node to itself: `p.c == p.c` → `true`; `identical(p.c, p.c)` →
    `true` (same OCaml value).

## Run

```bash
t run src/pipeline.t
```
