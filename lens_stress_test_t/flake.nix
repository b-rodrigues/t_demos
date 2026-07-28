{
  description = "lens_stress_test_t — a T lens stress test project";

  inputs = {
    nixpkgs.url = "github:rstats-on-nix/nixpkgs/2026-06-23";
    flake-utils.url = "github:numtide/flake-utils";
    t-lang.url = "path:/home/brodrigues/Documents/repos/tlang";
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
            echo "T Project: lens_stress_test_t"
            echo "=================================================="
            echo ""
            echo "Available commands:"
            echo "  t repl              - Start T REPL"
            echo "  t run <file>        - Run a T file"
            echo "  t test              - Run tests"
            echo ""
            echo "To add dependencies:"
            echo "  * Add them to tproject.toml"
            echo "  * Run 't update' to sync flake.nix"
            echo ""
          '';
        };
      }
    );
}
