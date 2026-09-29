# capture_transparency_t

Node commands run in a fresh sandbox, not a closure. This demo pins down
exactly what crosses the node boundary:

1. **Frozen outer data** — outer values inline as literals.
2. **Local shadowing** — block assignments stay local.
3. **Quoted code** — `to_expr` bodies run later, at node runtime.
4. **Symbolic functions** — bare outer lambdas are not available in the
   sandbox; the node captures the failure as a first-class error.
5. **Explicit symbol errors** — calling a bare symbol fails fast with a
   `TypeError` instead of hanging.

```bash
nix develop --command t run --failfast src/pipeline.t
```
