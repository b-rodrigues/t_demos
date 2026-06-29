# Per-Node Flake Demo

Demonstrates per-node flake support in T pipelines with selective fallback.

Each pipeline node can optionally specify its own Nix flake via the `flake` named
argument. Runtime components are resolved independently:

| Component | Resolved from custom flake if… | Falls back to project if missing |
|-----------|-------------------------------|----------------------------------|
| `tBin` | `packages.${system}.default` | Project `t` binary |
| `r-env` | `packages.${system}.tlang-r` | `pkgs.rWrapper` (no `tlang-r`) |
| `tlangJl` | `packages.${system}.tlang-julia-path` | Project Julia path |
| `pkgs` | `legacyPackages.${system}` or `inputs.nixpkgs.legacyPackages` | Project nixpkgs |

This allows:

- **R-only flakes** (like `jbedo/rshells`) to provide R packages while T
  infrastructure comes from the project
- **Full t-lang flakes** to replace everything (nixpkgs, R/Python/Julia, T binary)
- **Different nixpkgs snapshots** per node

## Nodes

| Node | Flake | Runtime | Computation |
|------|-------|---------|-------------|
| `a` | (default project flake) | T | `sum([1..5])` → 15 |
| `b` | `github:b-rodrigues/tlang` | T | `length([1..10])` → 10 |
| `c` | `github:jbedo/rshells` | R (via `rn()`) | `mean(mtcars$mpg)` → ~20.09 |
| `d` | `path:../test_flake` | T | `map(x -> x*2, [1,2,3])` → [2,4,6] |

## Running

```bash
cd per_node_flake_t
t run src/pipeline.t
```
