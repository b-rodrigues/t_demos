# Per-Node Flake Demo

Demonstrates per-node flake support in T pipelines.

Each pipeline node can optionally specify its own Nix flake path via the
`flake` named argument in `node()`:

```t
p = pipeline {
  default = node(command = "uses project flake", runtime = T)
  custom  = node(command = "uses custom flake",  runtime = T, flake = "github:user/repo")
}
```

When a node specifies a custom flake, the entire runtime environment
(nixpkgs, R/Python/Julia packages, t-lang binary) comes from that flake
instead of the project-level flake. Nodes without a custom flake continue
to use the project defaults.
