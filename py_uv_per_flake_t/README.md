# py_uv_per_flake_t

Combines UV workspace Python dependency resolver with per-node custom flakes.

## What it tests

- `tproject.toml` with `[py-dependencies].resolver = "uv"` (UV workspace Python)
- Per-node custom flakes (`github:jbedo/rshells` for R, `github:NixOS/nixpkgs/nixos-24.11` for Julia)
- Python node using UV workspace + a custom nixpkgs flake (composition of both features)
- Multi-language pipeline: Python, T, R, and Julia nodes all running together
- Nix structural assertions (mkNodeEnv, pyResolver, mkVirtualEnv, per-flake env bindings)
- Correct computation results verified across all runtimes

## How to run

```bash
nix develop --command t run src/pipeline.t
```
