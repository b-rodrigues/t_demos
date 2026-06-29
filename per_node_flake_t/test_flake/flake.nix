{
  description = "Minimal test flake for per-node flake T demo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    t-lang.url = "github:b-rodrigues/tlang";
  };

  outputs = { self, nixpkgs, t-lang }: {
    legacyPackages.${builtins.currentSystem} =
      nixpkgs.legacyPackages.${builtins.currentSystem};

    packages.${builtins.currentSystem} = {
      default = t-lang.packages.${builtins.currentSystem}.default;
      tlang-r = t-lang.packages.${builtins.currentSystem}.tlang-r;
      tlang-julia-path = t-lang.packages.${builtins.currentSystem}.tlang-julia-path;
      "tlang-julia" = t-lang.packages.${builtins.currentSystem}."tlang-julia";
    };
  };
}
