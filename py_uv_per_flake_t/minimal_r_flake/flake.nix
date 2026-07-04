{
  description = "Minimal R-only flake (no dplyr) for per-node flake UV workspace demo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: {
    legacyPackages.${builtins.currentSystem} =
      nixpkgs.legacyPackages.${builtins.currentSystem};
  };
}
