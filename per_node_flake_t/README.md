# Per-Node Flake Demo

Demonstrates per-node flake support in T pipelines.

Each pipeline node can optionally specify its own Nix flake via the `flake`
named argument. The runtime environment (nixpkgs, R/Python/Julia packages)
comes from that flake when available. If the flake only provides a subset
(e.g. R packages without t-lang infrastructure), missing components fall
back to the project-level flake.

**Project-level package inheritance:** Package declarations from
`tproject.toml` (`[r-dependencies]`, `[py-dependencies]`, `[jl-dependencies]`)
are inherited by all nodes, including those using a custom per-node flake.
The per-node flake controls *which nixpkgs revision* packages are built from,
but `tproject.toml` controls *what packages* are installed. If you want a
fully self-contained flake, configure packages directly in the flake.

## Pipeline nodes

| Node | Flake | Runtime | Computation |
|------|-------|---------|-------------|
| `a` | project default | T | `sum([1,2,3,4,5])` |
| `b` | `github:b-rodrigues/tlang` | T | `length([10,20,30,40])` |
| `c` | `github:jbedo/rshells` | R | `mean(mtcars$mpg)` |
| `d` | `path:test_flake` | T | `map(\(x) x * 10, [1,2,3])` |
| `e` | `github:NixOS/nixpkgs/nixos-24.11` | Julia | `sum([1,2,3,4,5]) / length([1,2,3,4,5])` (Julia) |
| `f` | `github:jbedo/rshells` | R | dplyr availability check |
| `g` | `path:minimal_r_flake` | R | dplyr availability check |

The pipeline is built with `populate_pipeline(p, build = true)` and results
are verified with `read_node`.

## Running

```bash
cd t_demos/per_node_flake_t
nix develop --command t run src/pipeline.t
```
