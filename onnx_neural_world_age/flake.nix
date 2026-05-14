{
  description = "onnx_neural_world_age — a T data analysis project";

  inputs = {
    nixpkgs.url = "github:rstats-on-nix/nixpkgs/2026-04-02";
    flake-utils.url = "github:numtide/flake-utils";
    t-lang.url = "github:b-rodrigues/tlang/julia-support";
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

        # Python environment
        py-env = pkgs.python314.withPackages (python-pkgs: with python-pkgs; [
          scikit-learn
          skl2onnx
          onnxruntime
          pandas
          numpy
        ]);

        # Julia environment
        juliaPkg = pkgs.julia-lts.withPackages [ "Flux" "Zygote" "ChainRulesCore" "ZygoteRules" "JSON" "JLD2" "CSV" "DataFrames" ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            t-lang.packages.${system}.default
            py-env
            juliaPkg
          ];

          shellHook = ''
            echo "=================================================="
            echo "T Project: onnx_neural_world_age"
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
