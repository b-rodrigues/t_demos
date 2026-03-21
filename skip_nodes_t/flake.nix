{
  description = "skip_nodes_t — a T data analysis project focused on skipping nodes";

  inputs = {
    nixpkgs.url = "github:rstats-on-nix/nixpkgs/2026-03-21";
    flake-utils.url = "github:numtide/flake-utils";
    t-lang.url = "github:b-rodrigues/tlang/";
  };

  nixConfig = {
    extra-substituters = [
      "https://rstats-on-nix.cachix.org"
    ];
    extra-trusted-public-keys = [
      "rstats-on-nix.cachix.org-1:vdiiVgocg6WeJrODIqdprZRUrhi1JzhBnXv7aWI6+F0="
    ];
  };

  outputs = { self, nixpkgs, flake-utils, t-lang }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            t-lang.packages.${system}.default
          ];

          shellHook = ''
            echo "=================================================="
            echo "T Project: skip_nodes_t"
            echo "=================================================="
            echo ""
            echo "To run the demo:"
            echo "  t run src/skip_demo.t"
            echo ""
          '';
        };
      }
    );
}
