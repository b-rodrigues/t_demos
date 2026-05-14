{
  description = "companion_check_t — a T data analysis project";

  inputs = {
    nixpkgs.url = "github:rstats-on-nix/nixpkgs/2026-04-02";
    flake-utils.url = "github:numtide/flake-utils";
    t-lang.url = "github:b-rodrigues/tlang/v0.52.0-modified";
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
            t-lang.packages.${system}.tlang-r
            dplyr
            jsonlite
          ];
        };

        # Python environment
        py-env = pkgs.python314.withPackages (python-pkgs: with python-pkgs; [
          t-lang.packages.${system}.tlang-python
          pandas
        ]);

        # Julia environment
        juliaPkg = pkgs.julia-lts.withPackages [ "DataFrames" "JSON" "CSV" ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            t-lang.packages.${system}.default
            r-env
            py-env
            juliaPkg
          ];

          shellHook = ''
            export JULIA_LOAD_PATH=":${t-lang.packages.${system}.tlang-julia-path}:''${JULIA_LOAD_PATH:-}"
            echo "=================================================="
            echo "T Project: companion_check_t"
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
