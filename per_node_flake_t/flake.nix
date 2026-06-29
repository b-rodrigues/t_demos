{
  description = "Per-node flake demo for T pipelines";

  inputs = {
    nixpkgs.url = "github:rstats-on-nix/nixpkgs";
    t-lang.url = "github:b-rodrigues/tlang/v0.54.0";
  };

  nixConfig = {
    extra-substituters = [
      "https://rstats-on-nix.cachix.org"
    ];
    extra-trusted-public-keys = [
      "rstats-on-nix.cachix.org-1:vdiiVgocg6WeJrODIqdprZRUrhi1JzhBnXv7aWI6+F0="
    ];
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
