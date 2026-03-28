{
  description = "yanai_lercher_2020_t — a T data analysis project";

  inputs = {
    nixpkgs.url = "github:rstats-on-nix/nixpkgs/2026-03-28";
    flake-utils.url = "github:numtide/flake-utils";
    t-lang.url = "github:b-rodrigues/tlang/v0.51.2";
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

        # R environment
        r-env = pkgs.rWrapper.override {
          packages = with pkgs.rPackages; [
            dplyr
            ggplot2
          ];
        };

        # Python environment
        py-env = pkgs.python313.withPackages (python-pkgs: with python-pkgs; [
          numpy
          pillow
        ]);
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            t-lang.packages.${system}.default
            r-env
            py-env
          ];

          shellHook = ''
            echo "=================================================="
            echo "T Project: yanai_lercher_2020_t"
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
